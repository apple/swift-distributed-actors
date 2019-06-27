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

/// A `WorkerPool` represents a pool of actors that are all equally qualified to handle incoming messages.
///
/// Pool members may be local or remote, // TODO: and there should be ways to say "prefer local or something".
///
/// A pool can populate its member list using the `Receptionist` mechanism, and thus allows members to join and leave
/// dynamically, e.g. if a node joins or removes itself from the cluster.
///
/// TODO: A pool can be configured to terminate itself when any of its workers terminate or attempt to spawn replacements.
public struct WorkerPool<Message> {

    typealias Ref<Message> = WorkerPoolRef<Message>

    /// A selector defines how actors should be selected to participate in the pool.
    /// E.g. the `dynamic` mode uses a receptionist key, and will add any workers which register
    /// using this key to the pool. On the other hand, static configurations could restrict the set
    /// of members to be statically provided etc.
    public enum Selector<Message> {
        /// Instructs the `WorkerPool` to subscribe to given receptionist key, and add/remove
        /// any actors which register/leave with the receptionist using this key.
        case dynamic(Receptionist.RegistrationKey<Message>)
        // TODO: let awaitAtLeast: Int // before starting to direct traffic

        // TODO: case static(ActorRef<Message>)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State shared across all states of the WorkerPool

    let selector: WorkerPool.Selector<Message>

    init(selector: Selector<Message>) {
        self.selector = selector
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Public API, spawning the pool

    // TODO how can we move the spawn somewhere else so we don't have to pass in the system or context?
    // TODO round robin or what strategy?
    // TODO ActorName
    static public func spawn(_ system: ActorSystem, select selector: Selector<Message>, name: String) throws -> WorkerPoolRef<Message> {
        let ref = try system.spawn(WorkerPool(selector: selector).initial(), name: name)
        return .init(ref: ref)
    }

    // TODO actor name
    // TODO mirror whichever API the other spawn is
    static public func spawn<ParentMessage>(_ context: ActorContext<ParentMessage>, select selector: Selector<Message>, name: String) throws -> WorkerPoolRef<Message> {
        let ref = try context.spawn(WorkerPool(selector: selector).initial(), name: name)
        return .init(ref: ref)
    }
}

/// Contains the various state behaviors the `WorkerPool` can be in.
/// Immutable state shared across all of them is kept in the worker pool instance to avoid unnecessary passing around,
/// and state bound to a specific state of the state machine is kept in each appropriate behavior.
internal extension WorkerPool {

    /// Register with receptionist under `selector.key` and become `awaitingWorkers`.
     func initial() -> Behavior<WorkerPoolMessage<Message>> {
        return .setup { context in
            switch self.selector {
            case .dynamic(let key):
                context.system.receptionist.subscribe(
                    key: key,
                    subscriber: context.messageAdapter(for: Receptionist.Listing<Message>.self) { listing in
                        context.log.debug("Got listing for \(self.selector): \(listing)")
                        return .listing(listing)
                    })
            }

            return self.awaitingWorkers()
        }
    }

     func awaitingWorkers() -> Behavior<WorkerPoolMessage<Message>> {
        return .setup { context in
            let stash = StashBuffer(owner: context, capacity: 100)

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
                    workers.sort { l, r in l.path.description < r.path.description }

                    context.log.info("Flushing buffered messages (count: \(stash.count)) on initial worker listing (count: \(workers.count))")
                    return try stash.unstashAll(context: context, behavior: self.forwarding(to: workers))

                case .forward(let message):
                    context.log.debug("Buffering message (total: \(stash.count)) while awaiting for initial workers for pool...")
                    try stash.stash(message: .forward(message))
                    return .same
                }
            }
        }
    }

    // TODO: abstract how we keep them, for round robin / random etc
     func forwarding(to workers: [ActorRef<Message>]) -> Behavior<WorkerPoolMessage<Message>> {
        return .setup { context in
            // TODO would be some actual logic, that we can plug and play
            var _roundRobinPos = 0

            func selectWorker() -> ActorRef<Message> {
                let worker = workers[_roundRobinPos]
                _roundRobinPos = (_roundRobinPos + 1) % workers.count
                return worker
            }

            let _forwarding: Behavior<WorkerPoolMessage<Message>> =  .receive { context, poolMessage in
                switch poolMessage {
                case .forward(let message):
                    let selected = selectWorker()
                    selected.tell(message)
                    return .same

                case .listing(let listing):
                    guard !listing.refs.isEmpty else {
                        context.log.debug("Worker pool downsized to zero members, becoming `awaitingWorkers`.")
                        return self.awaitingWorkers()
                    }

                    var newWorkers = Array(listing.refs) // TODO smarter logic here, remove dead ones etc; keep stable round robin while new listing arrives
                    newWorkers.sort { l, r in l.path.description < r.path.description }

                    context.log.debug("Active workers: \(newWorkers.count)")
                    // TODO if no more workers may want to issue warnings or timeouts
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
                    remainingWorkers.removeAll { ref in ref.path == terminated.path } // TODO removeFirst is enough, but has no closure version
                    if remainingWorkers.count > 0 {
                        return self.forwarding(to: remainingWorkers)
                    } else {
                        return self.awaitingWorkers()
                    }
                }

            return _forwarding.orElse(eagerlyRemoteTerminatedWorkers)
        }
    }
}

public struct WorkerPoolRef<Message>: ReceivesMessages {
    @usableFromInline
    internal let ref: ActorRef<WorkerPoolMessage<Message>>

    internal init(ref: ActorRef<WorkerPoolMessage<Message>>) {
        self.ref = ref
    }

    @inlinable
    public func tell(_ message: Message) {
        self.ref.tell(.forward(message))
    }

    // other query methods

}

@usableFromInline
internal enum WorkerPoolMessage<Message> {
    case forward(Message)
    case listing(Receptionist.Listing<Message>)
}

