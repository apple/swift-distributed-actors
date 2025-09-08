//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Logging
import OrderedCollections

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Worker

/// Protocol to be implemented by workers participating in a simple ``WorkerPool``.
public protocol DistributedWorker: DistributedActor where ActorSystem == ClusterSystem {
    associatedtype WorkItem: Codable & Sendable
    associatedtype WorkResult: Codable & Sendable

    distributed func submit(work: WorkItem) async throws -> WorkResult
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: WorkerPool

/// A `WorkerPool` represents a pool of actors that are all equally qualified to handle incoming work items.
///
/// A pool can populate its member list using the `Receptionist` mechanism, and thus allows members to join and leave
/// dynamically, e.g. if a node joins or removes itself from the cluster.
public distributed actor WorkerPool<Worker: DistributedWorker>: DistributedWorker, LifecycleWatch, CustomStringConvertible where Worker.ActorSystem == ClusterSystem {
    public typealias ActorSystem = ClusterSystem
    public typealias WorkItem = Worker.WorkItem
    public typealias WorkResult = Worker.WorkResult

    lazy var log = Logger(actor: self)

    // Don't store `WorkerPoolSettings` or `Selector` because it would cause `WorkerPool`
    // to hold on to `Worker` references and prevent them from getting terminated.
    private var whenAllWorkersTerminated: AllWorkersTerminatedDirective {
        self.settings.whenAllWorkersTerminated
    }

    private var logLevel: Logger.Level {
        self.settings.logLevel
    }

    private var strategy: WorkerPool<Worker>.Strategy {
        self.settings.strategy
    }

    private let settings: WorkerPoolSettings<Worker>

    /// `Task` for subscribing to receptionist listing in case of `Selector.dynamic` mode.
    private var newWorkersSubscribeTask: Task<Void, Error>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: WorkerPool state

    /// The worker pool. Worker will be selected round-robin.
    private var workers: OrderedSet<WeakLocalRef<Worker>> = []
    private var roundRobinPos = 0

    /// Boolean flag to help determine if pool becomes empty because at least one worker has terminated.
    private var hasTerminatedWorkers = false
    /// Control for waiting and getting notified for new worker.
    private var newWorkerContinuations: OrderedSet<ClusterCancellableCheckedContinuation<Void>> = []

    public init(selector: Selector, actorSystem: ActorSystem) async throws {
        try await self.init(settings: .init(selector: selector), actorSystem: actorSystem)
    }

    public init(settings: WorkerPoolSettings<Worker>, actorSystem system: ActorSystem) async throws {
        try settings.validate()

        self.actorSystem = system
        self.settings = settings

        switch settings.selector.underlying {
        case .dynamic(let key):
            self.newWorkersSubscribeTask = Task {
                for await worker in await self.actorSystem.receptionist.listing(of: key) {
                    self.workers.append(WeakLocalRef(worker))

                    // Notify those waiting for new worker
                    log.log(
                        level: self.logLevel,
                        "Updated workers for \(key)",
                        metadata: [
                            "workers": "\(self.workers)",
                            "newWorkerContinuations": "\(self.newWorkerContinuations.count)",
                        ]
                    )
                    for (i, continuation) in self.newWorkerContinuations.enumerated().reversed() {
                        continuation.resume()
                        self.newWorkerContinuations.remove(at: i)
                    }
                    watchTermination(of: worker)
                }
            }
        case .static(let workers):
            self.workers.reserveCapacity(workers.count)
            self.workers = .init(workers)
            for actor in workers.compactMap(\.actor) {
                watchTermination(of: actor)
            }
        }
    }

    deinit {
        self.newWorkersSubscribeTask?.cancel()
    }

    public distributed func submit(work: WorkItem) async throws -> WorkResult {
        self.log.log(
            level: self.logLevel,
            "Incoming work, selecting worker",
            metadata: [
                "workers/count": "\(self.size)",
                "worker/item": "\(work)",
            ]
        )
        let worker = try await self.selectWorker(for: work)
        self.log.log(
            level: self.logLevel,
            "Selected worker, submitting [\(work)] to [\(worker)]",
            metadata: [
                "worker": "\(worker.id)",
                "workers/count": "\(self.size)",
            ]
        )
        return try await worker.submit(work: work)
    }

    distributed var size: Int {
        self.workers.count
    }

    private func selectWorker(for work: WorkItem) async throws -> Worker {
        // Wait if we haven't received the initial workers listing yet.
        // Otherwise, the pool has become empty because all workers have been terminated,
        // in which case we either wait for new worker or throw error.
        if self.workers.isEmpty {
            switch (self.hasTerminatedWorkers, self.whenAllWorkersTerminated) {
            case (false, _),  // if we never received any workers yet, wait for some to show up.
                (true, .awaitNewWorkers):
                self.log.log(level: self.logLevel, "Worker pool is empty, waiting for new worker.")

                try await _withClusterCancellableCheckedContinuation(of: Void.self) { cccc in
                    self.newWorkerContinuations.append(cccc)
                    let log = self.log
                    cccc.onCancel { cccc in
                        log.debug("Member selection was cancelled, call probably timed-out, schedule removal of continuation")
                        cccc.resume(throwing: CancellationError())
                        Task {
                            await self.removeWorkerWaitContinuation(cccc)
                        }
                    }
                }
            case (true, .throw(let error)):
                throw error
            }
        }

        guard let selected = nextWorker() else {
            switch self.whenAllWorkersTerminated {
            case .awaitNewWorkers:
                // try again
                return try await self.selectWorker(for: work)
            case .throw(let error):
                throw error
            }
        }

        guard let selectedWorker = selected.actor else {
            self.log.debug("Selected actor has deallocated: \(selected.id)!")
            // remove this actor from the pool
            self.terminated(actor: selected.id)
            // and, try again
            return try await self.selectWorker(for: work)
        }

        return selectedWorker
    }

    private func removeWorkerWaitContinuation(_ cccc: ClusterCancellableCheckedContinuation<Void>) {
        self.newWorkerContinuations.remove(cccc)
    }

    private func nextWorker() -> WeakLocalRef<Worker>? {
        switch self.strategy.underlying {
        case .random:
            return self.workers.shuffled().first
        case .simpleRoundRobin:
            if self.roundRobinPos >= self.size {
                self.roundRobinPos = 0  // loop around from zero
            }
            let selected = self.workers[self.roundRobinPos]
            self.roundRobinPos = self.workers.index(after: self.roundRobinPos) % self.size
            return selected
        }
    }

    public func terminated(actor id: Worker.ID) {
        self.log.debug("Worker terminated: \(id)", metadata: ["worker": "\(id)"])
        self.workers.remove(WeakLocalRef<Worker>(forRemoval: id))
        self.hasTerminatedWorkers = true
        self.roundRobinPos = 0  // FIXME: naively reset the round robin counter; we should do better than that
    }

    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

extension WorkerPool {
    /// Directive that decides how the pool should react when all of its workers have terminated.
    enum AllWorkersTerminatedDirective {
        /// Move the pool back to its initial state and wait for new workers to join.
        /// Messages sent to the pool while in this state will be buffered (up to a configured stash capacity)
        case awaitNewWorkers
        /// Throwing the following error if all workers it was routing to have terminated.
        case `throw`(WorkerPoolError)
    }
}

extension WorkerPool {
    /// A selector defines how actors should be selected to participate in the pool.
    /// E.g. the `dynamic` mode uses a receptionist key, and will add any workers which register
    /// using this key to the pool. On the other hand, static configurations could restrict the set
    /// of members to be statically provided etc.
    public struct Selector {
        enum _Selector {
            case dynamic(DistributedReception.Key<Worker>)
            /// Should be array of WeakLocalRefs not to create strong references to local actors
            case `static`([WeakLocalRef<Worker>])
        }

        let underlying: _Selector

        /// Instructs the `WorkerPool` to subscribe to given receptionist key, and add/remove
        /// any actors which register/leave with the receptionist using this key.
        public static func dynamic(_ key: DistributedReception.Key<Worker>) -> Selector {
            .init(underlying: .dynamic(key))
        }

        /// Instructs the `WorkerPool` to use only the specified actors for routing.
        ///
        /// The actors will be removed from the pool if they terminate and will not be replaced automatically.
        /// Thus, the workers should use a `_SupervisionStrategy` appropriate for them so they can survive failures.
        ///
        /// ### No remaining workers
        /// The worker pool will terminate itself if all of its static workers have terminated.
        /// You may death-watch the worker pool in order to react to this situation, e.g. by spawning a replacement pool,
        /// or gracefully shutting down your application.
        public static func `static`(_ workers: [Worker]) -> Selector {
            .init(underlying: .static(workers.map(WeakLocalRef.init)))
        }
    }

    public struct Strategy {
        enum _Strategy {
            case random
            case simpleRoundRobin
        }

        let underlying: _Strategy

        /// Simple random selection on every target worker selection.
        public static var random: Strategy {
            .init(underlying: .random)
        }

        /// Round-robin strategy which attempts to go "around" known workers one-by-one
        /// giving them equal amounts of work. This strategy is NOT strict, and when new
        /// workers arrive at the pool it may result in submitting work to previously notified
        /// workers as the round-robin strategy "resets".
        ///
        /// We could consider implementing a strict round robin strategy which remains strict even
        /// as new workers arrive in the pool.
        public static var simpleRoundRobin: Strategy {
            .init(underlying: .simpleRoundRobin)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: WorkerPool Errors

public struct WorkerPoolError: Error, CustomStringConvertible {
    internal enum _WorkerPoolError {
        // --- runtime errors
        case staticPoolExhausted(String)

        // --- configuration errors
        case emptyStaticWorkerPool(String)
        case illegalAwaitNewWorkersForStaticPoolConfigured(String)
    }

    internal class _Storage {
        let error: _WorkerPoolError
        let file: String
        let line: UInt

        init(error: _WorkerPoolError, file: String, line: UInt) {
            self.error = error
            self.file = file
            self.line = line
        }
    }

    let underlying: _Storage

    internal init(_ error: _WorkerPoolError, file: String = #fileID, line: UInt = #line) {
        self.underlying = _Storage(error: error, file: file, line: line)
    }

    public var description: String {
        "\(Self.self)(\(self.underlying.error), at: \(self.underlying.file):\(self.underlying.line))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: WorkerPool Settings

/// Used to configure a `WorkerPool`.
public struct WorkerPoolSettings<Worker: DistributedWorker> where Worker.ActorSystem == ClusterSystem {
    /// Log level at which the worker pool will log its internal messages.
    /// Usually not interesting unless debugging the workings of a worker pool and workers joining/leaving it.
    var logLevel: Logger.Level = .trace

    /// Configures how to select / discover actors for the pool.
    var selector: WorkerPool<Worker>.Selector

    /// Configures how the "next" worker is determined for submitting a work request.
    /// Generally random strategies or a form of round robin are preferred, but we
    /// could implement more sophisticated workload balancing/estimating strategies as well.
    ///
    /// Defaults to a simple round-robin strategy.
    var strategy: WorkerPool<Worker>.Strategy

    /// Determine what action should be taken once the number of alive workers in the pool reaches zero (after being positive for at least a moment).
    ///
    /// The default value depends on the `selector` and is:
    /// - `.crash` for the `.static` selector,
    /// - `.awaitNewWorkers` for the `.dynamic` selector, as it is assumed that replacement workers will likely be spawned
    ///    in place of terminated workers. Messages sent to the pool while no workers are available will be buffered (up to `noWorkersAvailableBufferSize` messages).
    var whenAllWorkersTerminated: WorkerPool<Worker>.AllWorkersTerminatedDirective

    public init(selector: WorkerPool<Worker>.Selector, strategy: WorkerPool<Worker>.Strategy = .random) {
        self.selector = selector
        self.strategy = strategy

        switch selector.underlying {
        case .dynamic:
            self.whenAllWorkersTerminated = .awaitNewWorkers
        case .static:
            let message = "Static worker pool exhausted, all workers have terminated, selector was [\(selector)]."
            self.whenAllWorkersTerminated = .throw(WorkerPoolError(.staticPoolExhausted(message)))
        }
    }

    @discardableResult
    public func validate() throws -> WorkerPoolSettings {
        switch self.selector.underlying {
        case .static(let workers) where workers.isEmpty:
            throw WorkerPoolError(.emptyStaticWorkerPool("Illegal empty collection passed to `.static` worker pool!"))
        case .static(let workers):
            if case .awaitNewWorkers = self.whenAllWorkersTerminated {
                let message = """
                    WorkerPool configured as [.static(\(workers))], MUST NOT be configured to await for new workers \
                    as new workers are impossible to spawn and add to the pool in the static configuration. The pool \
                    MUST terminate when in .static mode and all workers terminate. Alternatively, use a .dynamic pool, \
                    and provide an initial set of workers.
                    """
                throw WorkerPoolError(.illegalAwaitNewWorkersForStaticPoolConfigured(message))
            }
        default:
            ()  // ok
        }

        return self
    }
}
