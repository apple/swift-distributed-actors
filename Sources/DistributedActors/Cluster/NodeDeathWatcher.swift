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
import NIO

/// Implements `DeathWatch` semantics in presence of `Node` failures.
///
/// Depends on a failure detector to actually detect a node failure, however once detected,
/// it handles notifying all _local_ actors which have watched at least one actor the terminating node.
///
/// ### Implementation
/// In order to avoid every actor having to subscribe to cluster events and individually handle the relationship between those
/// and individually watched actors, the watcher handles subscribing for cluster events on behalf of actors which watch
/// other actors on remote nodes, and messages them `SystemMessage.nodeTerminated(node)` upon node termination (down),
/// which are in turn translated by the actors locally to `SystemMessage.terminated(ref:existenceConfirmed:addressTerminated:true)`
///
/// to any actor which watched at least one actor on a node that has been downed.
///
/// Actor which is notified automatically when a remote actor is `context.watch()`-ed.
///
/// Allows manually mocking membership changes to trigger terminated notifications.
internal final class NodeDeathWatcherInstance: NodeDeathWatcher {
    private let selfNode: UniqueNode
    private var membership: Cluster.Membership

    /// Members which have been `removed`
    // TODO: clear after a few days
    private var nodeTombstones: Set<UniqueNode> = []

    /// Mapping between remote node, and actors which have watched some actors on given remote node.
    private var remoteWatchers: [UniqueNode: Set<AddressableActorRef>] = [:]

    init(selfNode: UniqueNode) {
        self.selfNode = selfNode
        self.membership = .empty
    }

    func onActorWatched(by watcher: AddressableActorRef, remoteNode: UniqueNode) {
        guard !self.nodeTombstones.contains(remoteNode) else {
            // the system the watcher is attempting to watch has terminated before the watch has been processed,
            // thus we have to immediately reply with a termination system message, as otherwise it would never receive one
            watcher._sendSystemMessage(.nodeTerminated(remoteNode))
            return
        }

        if watcher.address.isRemote { // isKnownRemote(localAddress: context.address) {
            // a failure detector must never register non-local actors, it would not make much sense,
            // as they should have their own local failure detectors on their own systems.
            // If we reach this it is most likely a bug in the library itself.
            let err = NodeDeathWatcherError.watcherActorWasNotLocal(watcherAddress: watcher.address, localNode: self.selfNode)
            return fatalErrorBacktrace("Attempted registering non-local actor with node-death watcher: \(err)")
        }

        var existingWatchers = self.remoteWatchers[remoteNode] ?? []
        existingWatchers.insert(watcher) // FIXME: we have to remove it once it terminates...

        self.remoteWatchers[remoteNode] = existingWatchers
    }

    func onMembershipChanged(_ change: Cluster.MembershipChange) {
        guard let change = self.membership.applyMembershipChange(change) else {
            return // no change, nothing to act on
        }

        // TODO: make sure we only handle ONCE?
        if change.toStatus >= .down {
            // can be: down, leaving or removal.
            // on any of those we want to ensure we handle the "down"
            self.handleAddressDown(change)
        }
    }

    func handleAddressDown(_ change: Cluster.MembershipChange) {
        let terminatedNode = change.node
        if let watchers = self.remoteWatchers.removeValue(forKey: terminatedNode) {
            for ref in watchers {
                // we notify each actor that was watching this remote address
                ref._sendSystemMessage(.nodeTerminated(terminatedNode))
            }
        }

        // we need to keep a tombstone, so we can immediately reply with a terminated,
        // in case another watch was just in progress of being made
        self.nodeTombstones.insert(terminatedNode)
    }
}

/// The callbacks defined on a `NodeDeathWatcher` are invoked by an enclosing actor, and thus synchronization is guaranteed
internal protocol NodeDeathWatcher {
    /// Called when the `watcher` watches a remote actor which resides on the `remoteNode`.
    /// A failure detector may have to start monitoring this node using some internal mechanism,
    /// in order to be able to signal the watcher in case the node terminates (e.g. the node crashes).
    func onActorWatched(by watcher: AddressableActorRef, remoteNode: UniqueNode)

    /// Called when the cluster membership changes.
    ///
    /// A failure detector should signal termination signals if it notices that a previously monitored node has now
    /// left the cluster.
    // TODO: this will change to subscribing to cluster events once those land
    func onMembershipChanged(_ change: Cluster.MembershipChange)
}

enum NodeDeathWatcherShell {
    typealias Ref = ActorRef<Message>

    static var naming: ActorNaming {
        "nodeDeathWatcher"
    }

    /// Message protocol for interacting with the failure detector.
    /// By default, the `FailureDetectorShell` handles these messages by interpreting them with an underlying `FailureDetector`,
    /// it would be possible however to allow implementing the raw protocol by user actors if we ever see the need for it.
    internal enum Message: NotTransportableActorMessage {
        case remoteActorWatched(watcher: AddressableActorRef, remoteNode: UniqueNode)
        case membershipSnapshot(Cluster.Membership)
        case membershipChange(Cluster.MembershipChange)
    }

    // FIXME: death watcher is incomplete, should handle snapshot!!
    static func behavior(clusterEvents: EventStream<Cluster.Event>) -> Behavior<Message> {
        .setup { context in
            let instance = NodeDeathWatcherInstance(selfNode: context.system.settings.cluster.uniqueBindNode)

            context.system.cluster.events.subscribe(context.subReceive(Cluster.Event.self) { event in
                switch event {
                case .membershipChange(let change) where change.isAtLeastDown:
                    instance.handleAddressDown(change)
                default:
                    () // ignore other changes, we only need to react on nodes becoming DOWN
                }
            })

            return NodeDeathWatcherShell.behavior(instance)
        }
    }

    static func behavior(_ instance: NodeDeathWatcherInstance) -> Behavior<Message> {
        .receiveMessage { message in

            let lastMembership: Cluster.Membership = .empty // TODO: To be mutated based on membership changes

            switch message {
            case .remoteActorWatched(let watcher, let remoteNode):
                _ = instance.onActorWatched(by: watcher, remoteNode: remoteNode) // TODO: return and interpret directives

            case .membershipSnapshot(let membership):
                let diff = Cluster.Membership._diff(from: lastMembership, to: membership)

                for change in diff.changes {
                    _ = instance.onMembershipChanged(change) // TODO: return and interpret directives
                }

            case .membershipChange(let change):
                _ = instance.onMembershipChanged(change) // TODO: return and interpret directives
            }
            return .same
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public enum NodeDeathWatcherError: Error {
    case attemptedToFailUnknownAddress(Cluster.Membership, UniqueNode)
    case watcherActorWasNotLocal(watcherAddress: ActorAddress, localNode: UniqueNode?)
}
