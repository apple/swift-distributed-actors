//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

/// A `WorkerPool` represents a pool of actors that are all equally qualified to handle incoming messages.
///
/// Pool members may be local or remote, // TODO: and there should be ways to say "prefer local or something".
///
/// A pool can populate its member list using the `Receptionist` mechanism, and thus allows members to join and leave
/// dynamically, e.g. if a node joins or removes itself from the cluster.
///
// TODO: A pool can be configured to terminate itself when any of its workers terminate or attempt to spawn replacements.
public class WorkerPool<Message: ActorMessage> {
    typealias Ref = WorkerPoolRef<Message>

    /// A selector defines how actors should be selected to participate in the pool.
    /// E.g. the `dynamic` mode uses a receptionist key, and will add any workers which register
    /// using this key to the pool. On the other hand, static configurations could restrict the set
    /// of members to be statically provided etc.
    public enum Selector {
        /// Instructs the `WorkerPool` to subscribe to given receptionist key, and add/remove
        /// any actors which register/leave with the receptionist using this key.
        case dynamic(Receptionist.RegistrationKey<ActorRef<Message>>)
        // TODO: let awaitAtLeast: Int // before starting to direct traffic

        /// Instructs the `WorkerPool` to use only the specified actors for routing.
        ///
        /// The actors will be removed from the pool if they terminate and will not be replaced automatically.
        /// Thus, the workers should use a `SupervisionStrategy` appropriate for them so they can survive failures.
        ///
        /// ### No remaining workers
        /// The worker pool will terminate itself if all of its static workers have terminated.
        /// You may death-watch the worker pool in order to react to this situation, e.g. by spawning a replacement pool,
        /// or gracefully shutting down your application.
        case `static`([ActorRef<Message>])
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State shared across all states of the WorkerPool

    var settings: WorkerPoolSettings<Message>
    var selector: Selector {
        self.settings.selector
    }

    init(settings: WorkerPoolSettings<Message>) {
        self.settings = settings
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Public API, spawning the pool

    // TODO: how can we move the spawn somewhere else so we don't have to pass in the system or context?
    // TODO: round robin or what strategy?
    public static func spawn(
        _ factory: ActorRefFactory, _ naming: ActorNaming, props: Props = Props(),
        select selector: WorkerPool<Message>.Selector,
        file: String = #file, line: UInt = #line
    ) throws -> WorkerPoolRef<Message> {
        // TODO: pass in settings rather than create them here
        let settings = try WorkerPoolSettings<Message>(selector: selector).validate()

        let pool: WorkerPool<Message> = WorkerPool(settings: settings)
        let ref = try factory.spawn(naming, of: WorkerPoolMessage<Message>.self, props: props, file: file, line: line, pool.initial())
        return .init(ref: ref)
    }
}

/// Contains the various state behaviors the `WorkerPool` can be in.
/// Immutable state shared across all of them is kept in the worker pool instance to avoid unnecessary passing around,
/// and state bound to a specific state of the state machine is kept in each appropriate behavior.
internal extension WorkerPool {
    typealias PoolBehavior = Behavior<WorkerPoolMessage<Message>>

    /// Register with receptionist under `selector.key` and become `awaitingWorkers`.
    func initial() -> PoolBehavior {
        .setup { context in
            switch self.selector {
            case .dynamic(let key):
                context.system.receptionist.subscribe(
                    key: key,
                    subscriber: context.messageAdapter(from: Receptionist.Listing<ActorRef<Message>>.self) { listing in
                        context.log.log(level: self.settings.logLevel, "Got listing for \(self.selector): \(listing)")
                        return .listing(listing)
                    }
                )
                return self.awaitingWorkers()

            case .static(let workers):
                return self.forwarding(to: workers)
            }
        }
    }

    func awaitingWorkers() -> PoolBehavior {
        .setup { context in
            let stash = StashBuffer(owner: context, capacity: self.settings.noWorkersAvailableStashCapacity)

            return .receive { context, message in
                switch message {
                case .listing(let listing):
                    guard listing.refs.count > 0 else {
                        // a zero size listing is useless to us, we need at least one worker so we can flush the messages to it
                        // TODO: configurable "when to flush"
                        return .same
                    }

                    // naive "somewhat effort" on keeping the balancing stable when new members will be joining
                    var workers = Array(listing.refs)
                    workers.sort { l, r in l.address.description < r.address.description }

                    context.log.log(level: self.settings.logLevel, "Flushing buffered messages (count: \(stash.count)) on initial worker listing (count: \(workers.count))")
                    return try stash.unstashAll(context: context, behavior: self.forwarding(to: workers))

                case .forward(let message):
                    context.log.log(level: self.settings.logLevel, "Buffering message (total: \(stash.count)) while waiting for initial workers to join the worker pool...")
                    try stash.stash(message: .forward(message))
                    return .same
                }
            }
        }
    }

    // TODO: abstract how we keep them, for round robin / random etc
    func forwarding(to workers: [ActorRef<Message>]) -> PoolBehavior {
        .setup { context in
            // TODO: would be some actual logic, that we can plug and play
            var _roundRobinPos = 0

            func selectWorker() -> ActorRef<Message> {
                let worker = workers[_roundRobinPos]
                _roundRobinPos = (_roundRobinPos + 1) % workers.count
                return worker
            }

            let _forwarding: Behavior<WorkerPoolMessage<Message>> = .receive { context, poolMessage in
                switch poolMessage {
                case .forward(let message):
                    let selected = selectWorker()
                    context.log.log(level: self.settings.logLevel, "Forwarding [\(message)] to [\(selected)]")
                    selected.tell(message)
                    return .same

                case .listing(let listing):
                    guard !listing.refs.isEmpty else {
                        context.log.log(level: self.settings.logLevel, "Worker pool downsized to zero members, becoming `awaitingWorkers`.")
                        return self.awaitingWorkers()
                    }

                    var newWorkers = Array(listing.refs) // TODO: smarter logic here, remove dead ones etc; keep stable round robin while new listing arrives
                    newWorkers.sort { l, r in l.address.description < r.address.description }

                    context.log.log(level: self.settings.logLevel, "Active workers: \(newWorkers.count)")
                    // TODO: if no more workers may want to issue warnings or timeouts
                    return self.forwarding(to: newWorkers)
                }
            }

            // While we would remove terminated workers thanks to a new Listing arriving in any case,
            // the listing can arrive much later than a direct Terminated message - allowing for a longer
            // time window in which we are under risk of forwarding work to an already dead actor.
            //
            // In order to make this time window smaller, we explicitly watch and remove any workers we are forwarding to.
            workers.forEach { context.watch($0) }

            let eagerlyRemoteTerminatedWorkers: Behavior<WorkerPoolMessage<Message>> =
                .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                    var remainingWorkers = workers
                    remainingWorkers.removeAll { ref in ref.address == terminated.address } // TODO: removeFirst is enough, but has no closure version

                    if remainingWorkers.count > 0 {
                        return self.forwarding(to: remainingWorkers)
                    } else {
                        switch self.settings.whenAllWorkersTerminated {
                        case .awaitNewWorkers:
                            return self.awaitingWorkers()
                        case .crash(let error):
                            throw error
                        }
                    }
                }

            return _forwarding.orElse(eagerlyRemoteTerminatedWorkers)
        }
    }

    /// Directive that decides how the pool should react when all of its workers have terminated.
    enum AllWorkersTerminatedDirective {
        /// Move the pool back to its initial state and wait for new workers to join.
        /// Messages sent to the pool while in this state will be buffered (up to a configured stash capacity)
        case awaitNewWorkers
        /// Crash the actor by throwing the following error if all workers it was routing to have terminated.
        case crash(WorkerPoolError)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Worker Pool Ref

public struct WorkerPoolRef<Message: ActorMessage>: ReceivesMessages {
    @usableFromInline
    internal let _ref: ActorRef<WorkerPoolMessage<Message>>

    internal init(ref: ActorRef<WorkerPoolMessage<Message>>) {
        self._ref = ref
    }

    @inlinable
    public func tell(_ message: Message, file: String = #file, line: UInt = #line) {
        self._ref.tell(.forward(message), file: file, line: line)
    }

    public func ask<Answer: ActorMessage>(
        for type: Answer.Type = Answer.self,
        timeout: TimeAmount,
        file: String = #file, function: String = #function, line: UInt = #line,
        _ makeQuestion: @escaping (ActorRef<Answer>) -> Message
    ) -> AskResponse<Answer> {
        self._ref.ask(for: type, timeout: timeout, file: file, function: function, line: line) { replyTo in
            .forward(makeQuestion(replyTo))
        }
    }

    public var address: ActorAddress {
        self._ref.address
    }

    public var path: ActorPath {
        self.address.path
    }
}

@usableFromInline
internal enum WorkerPoolMessage<Message: ActorMessage>: NonTransportableActorMessage {
    case forward(Message)
    case listing(Receptionist.Listing<ActorRef<Message>>)
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
public struct WorkerPoolSettings<Message: ActorMessage> { // TODO: need the Codable?
    /// Log level at which the worker pool will log its internal messages.
    /// Usually not interesting unless debugging the workings of a worker pool and workers joining/leaving it.
    var logLevel: Logger.Level = .trace

    /// Configures how to select / discover actors for the pool.
    var selector: WorkerPool<Message>.Selector

    /// Determine what action should be taken once the number of alive workers in the pool reaches zero (after being positive for at least a moment).
    ///
    /// The default value depends on the `selector` and is:
    /// - `.crash` for the `.static` selector,
    /// - `.awaitNewWorkers` for the `.dynamic` selector, as it is assumed that replacement workers will likely be spawned
    //    in place of terminated workers. Messages sent to the pool while no workers are available will be buffered (up to `noWorkersAvailableBufferSize` messages).
    var whenAllWorkersTerminated: WorkerPool<Message>.AllWorkersTerminatedDirective

    /// Maximum number of messages that will be stashed in the pool if no workers are available,
    /// e.g. because dynamic selection has not located any workers yet.
    var noWorkersAvailableStashCapacity: Int = 1024

    public init(selector: WorkerPool<Message>.Selector) {
        self.selector = selector

        switch selector {
        case .dynamic:
            self.whenAllWorkersTerminated = .awaitNewWorkers
        case .static:
            let message = "Static worker pool exhausted, all workers have terminated, selector was [\(selector)]; terminating myself."
            self.whenAllWorkersTerminated = .crash(.staticPoolExhausted(message))
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
