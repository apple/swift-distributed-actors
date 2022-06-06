//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Worker

public protocol DistributedWorker: DistributedActor {
    associatedtype WorkItem: Codable
    associatedtype WorkResult: Codable

    distributed func submit(work: WorkItem) async throws -> WorkResult
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: WorkerPool

/// A `WorkerPool` represents a pool of actors that are all equally qualified to handle incoming work items.
///
/// Pool members may be local or remote, // TODO: and there should be ways to say "prefer local or something".
///
/// A pool can populate its member list using the `Receptionist` mechanism, and thus allows members to join and leave
/// dynamically, e.g. if a node joins or removes itself from the cluster.
///
// TODO: A pool can be configured to terminate itself when any of its workers terminate or attempt to spawn replacements.
public distributed actor WorkerPool<Worker: DistributedWorker>: DistributedWorker, LifecycleWatch, CustomStringConvertible where Worker.ActorSystem == ClusterSystem {
    public typealias ActorSystem = ClusterSystem
    public typealias WorkItem = Worker.WorkItem
    public typealias WorkResult = Worker.WorkResult

    /// A selector defines how actors should be selected to participate in the pool.
    /// E.g. the `dynamic` mode uses a receptionist key, and will add any workers which register
    /// using this key to the pool. On the other hand, static configurations could restrict the set
    /// of members to be statically provided etc.
    public enum Selector {
        /// Instructs the `WorkerPool` to subscribe to given receptionist key, and add/remove
        /// any actors which register/leave with the receptionist using this key.
        case dynamic(DistributedReception.Key<Worker>)
        // TODO: let awaitAtLeast: Int // before starting to direct traffic

        /// Instructs the `WorkerPool` to use only the specified actors for routing.
        ///
        /// The actors will be removed from the pool if they terminate and will not be replaced automatically.
        /// Thus, the workers should use a `_SupervisionStrategy` appropriate for them so they can survive failures.
        ///
        /// ### No remaining workers
        /// The worker pool will terminate itself if all of its static workers have terminated.
        /// You may death-watch the worker pool in order to react to this situation, e.g. by spawning a replacement pool,
        /// or gracefully shutting down your application.
        case `static`([Worker])
    }

    // Don't store `WorkerPoolSettings` or `Selector` because it would cause `WorkerPool`
    // to hold on to `Worker` references and prevent them from getting terminated.
    private let whenAllWorkersTerminated: AllWorkersTerminatedDirective
    private let logLevel: Logger.Level

    /// `Task` for subscribing to receptionist listing in case of `Selector.dynamic` mode.
    private var newWorkersSubscribeTask: Task<Void, Error>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: WorkerPool state

    /// The worker pool. Worker will be selected round-robin.
    private var workers: [Worker.ID: Weak<Worker>] = [:]
    private var roundRobinPos = 0

    /// Boolean flag to help determine if pool becomes empty because at least one worker has terminated.
    private var hasTerminatedWorkers = false
    /// Control for waiting and getting notified for new worker.
    private var newWorkerContinuations: [CheckedContinuation<Void, Never>] = []

    init(settings: WorkerPoolSettings<Worker>, system: ActorSystem) async {
        self.actorSystem = system
        self.whenAllWorkersTerminated = settings.whenAllWorkersTerminated
        self.logLevel = settings.logLevel

        switch settings.selector {
        case .dynamic(let key):
            self.newWorkersSubscribeTask = Task {
                for await worker in await self.actorSystem.receptionist.listing(of: key) {
                    self.actorSystem.log.log(level: self.logLevel, "Got listing member for \(key): \(worker)")
                    self.workers[worker.id] = Weak(worker)
                    // Notify those waiting for new worker
                    for (i, continuation) in self.newWorkerContinuations.enumerated().reversed() {
                        continuation.resume()
                        self.newWorkerContinuations.remove(at: i)
                    }
                    watchTermination(of: worker) { self.onWorkerTerminated(id: $0) }
                }
            }
        case .static(let workers):
            workers.forEach { worker in
                self.workers[worker.id] = Weak(worker)
                watchTermination(of: worker) { self.onWorkerTerminated(id: $0) }
            }
        }
    }

    deinit {
        self.newWorkersSubscribeTask?.cancel()
    }

    public distributed func submit(work: WorkItem) async throws -> WorkResult {
        let worker = try await self.selectWorker()
        self.actorSystem.log.log(level: self.logLevel, "Submitting [\(work)] to [\(worker)]")
        return try await worker.submit(work: work)
    }

    // FIXME: make this a computed property instead when https://github.com/apple/swift/pull/42321 is in
    internal distributed func size() async throws -> Int {
        self.workers.count
    }

    private func selectWorker() async throws -> Worker {
        // Wait if we haven't received the initial workers listing yet.
        // Otherwise, the pool has become empty because all workers have been terminated,
        // in which case we either wait for new worker or throw error.
        if self.workers.isEmpty {
            switch (self.hasTerminatedWorkers, self.whenAllWorkersTerminated) {
            case (false, _), (true, .awaitNewWorkers):
                self.actorSystem.log.log(level: self.logLevel, "Worker pool is empty, waiting for new worker.")
                try await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.newWorkerContinuations.append(continuation)
                }
            case (true, .throw(let error)):
                throw error
            }
        }

        let selectedWorkerID = self.nextWorkerID()
        if let worker = self.workers[selectedWorkerID]?.actor {
            return worker
        } else {
            // Worker terminated; clean up and try again
            self.onWorkerTerminated(id: selectedWorkerID)
            return try await self.selectWorker()
        }
    }

    private func nextWorkerID() -> Worker.ID {
        var ids = Array(self.workers.keys)
        ids.sort { l, r in l.description < r.description }

        let selected = ids[self.roundRobinPos]
        self.roundRobinPos = (self.roundRobinPos + 1) % ids.count
        return selected
    }

    private func onWorkerTerminated(id: Worker.ID) {
        self.workers.removeValue(forKey: id)
        self.hasTerminatedWorkers = true
        self.roundRobinPos = 0
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Public API, spawning the pool

    // TODO: how can we move the spawn somewhere else so we don't have to pass in the system or context?
    // TODO: round robin or what strategy?
    public static func _spawn(
        _ system: ActorSystem,
        select selector: WorkerPool<Worker>.Selector,
        file: String = #file, line: UInt = #line
    ) async throws -> WorkerPool<Worker> {
        // TODO: pass in settings rather than create them here
        let settings = try WorkerPoolSettings<Worker>(selector: selector).validate()
        return await WorkerPool(settings: settings, system: system)
    }

    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

internal extension WorkerPool {
    /// Directive that decides how the pool should react when all of its workers have terminated.
    enum AllWorkersTerminatedDirective {
        /// Move the pool back to its initial state and wait for new workers to join.
        /// Messages sent to the pool while in this state will be buffered (up to a configured stash capacity)
        case awaitNewWorkers
        /// Throwing the following error if all workers it was routing to have terminated.
        case `throw`(WorkerPoolError)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: WorkerPool Errors

public enum WorkerPoolError: Error {
    // --- runtime errors
    case staticPoolExhausted(String)

    // --- configuration errors
    case emptyStaticWorkerPool(String)
    case illegalAwaitNewWorkersForStaticPoolConfigured(String)
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

    /// Determine what action should be taken once the number of alive workers in the pool reaches zero (after being positive for at least a moment).
    ///
    /// The default value depends on the `selector` and is:
    /// - `.crash` for the `.static` selector,
    /// - `.awaitNewWorkers` for the `.dynamic` selector, as it is assumed that replacement workers will likely be spawned
    //    in place of terminated workers. Messages sent to the pool while no workers are available will be buffered (up to `noWorkersAvailableBufferSize` messages).
    var whenAllWorkersTerminated: WorkerPool<Worker>.AllWorkersTerminatedDirective

    public init(selector: WorkerPool<Worker>.Selector) {
        self.selector = selector

        switch selector {
        case .dynamic:
            self.whenAllWorkersTerminated = .awaitNewWorkers
        case .static:
            let message = "Static worker pool exhausted, all workers have terminated, selector was [\(selector)]."
            self.whenAllWorkersTerminated = .throw(.staticPoolExhausted(message))
        }
    }

    public func validate() throws -> WorkerPoolSettings {
        switch self.selector {
        case .static(let workers) where workers.isEmpty:
            throw WorkerPoolError.emptyStaticWorkerPool("Illegal empty collection passed to `.static` worker pool!")
        case .static(let workers):
            if case .awaitNewWorkers = self.whenAllWorkersTerminated {
                let message = """
                WorkerPool configured as [.static(\(workers))], MUST NOT be configured to await for new workers \
                as new workers are impossible to spawn and add to the pool in the static configuration. The pool \
                MUST terminate when in .static mode and all workers terminate. Alternatively, use a .dynamic pool, \
                and provide an initial set of workers.
                """
                throw WorkerPoolError.illegalAwaitNewWorkersForStaticPoolConfigured(message)
            }
        default:
            () // ok
        }

        return self
    }
}
