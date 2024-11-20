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
/// which are in turn translated by the actors locally to `SystemMessage.terminated(ref:existenceConfirmed:idTerminated:true)`
/// to any actor which watched at least one actor on a node that has been downed.
///
/// Actor which is notified automatically when a remote actor is `context.watch()`-ed.
///
/// Allows manually mocking membership changes to trigger terminated notifications.
internal final class NodeDeathWatcherInstance: NodeDeathWatcher {
    private let selfNode: Cluster.Node
    private var membership: Cluster.Membership

    /// Members which have been `removed`
    // TODO: clear after a few days, or some max count of nodes, use sorted set for this
    private var nodeTombstones: Set<Cluster.Node> = []

    struct WatcherAndCallback: Hashable {
        /// Address of the local watcher which had issued this watch
        let watcherID: ClusterSystem.ActorID
        let callback: @Sendable (Cluster.Node) async -> Void

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.watcherID)
        }

        static func == (lhs: WatcherAndCallback, rhs: WatcherAndCallback) -> Bool {
            lhs.watcherID == rhs.watcherID
        }
    }

    /// Mapping between remote node, and actors which have watched some actors on given remote node.
    private var remoteWatchers: [Cluster.Node: Set<_AddressableActorRef>] = [:]
    private var remoteWatchCallbacks: [Cluster.Node: Set<WatcherAndCallback>] = [:]

    init(selfNode: Cluster.Node) {
        self.selfNode = selfNode
        self.membership = .empty
    }

    @available(*, deprecated, message: "will be replaced by distributed actor / closure version")
    func onActorWatched(by watcher: _AddressableActorRef, remoteNode: Cluster.Node) {
        guard !self.nodeTombstones.contains(remoteNode) else {
            // the system the watcher is attempting to watch has terminated before the watch has been processed,
            // thus we have to immediately reply with a termination system message, as otherwise it would never receive one
            watcher._sendSystemMessage(.nodeTerminated(remoteNode))
            return
        }

        guard watcher.id._isLocal else {
            // a failure detector must never register non-local actors, it would not make much sense,
            // as they should have their own local failure detectors on their own systems.
            // If we reach this it is most likely a bug in the library itself.
            let err = NodeDeathWatcherError.watcherActorWasNotLocal(watcherID: watcher.id, localNode: self.selfNode)
            return fatalErrorBacktrace("Attempted registering non-local actor with node-death watcher: \(err)")
        }

        var existingWatchers = self.remoteWatchers[remoteNode] ?? []
        existingWatchers.insert(watcher)  // FIXME: we have to remove it once it terminates...

        self.remoteWatchers[remoteNode] = existingWatchers
    }

    func onActorWatched(
        on remoteNode: Cluster.Node,
        by watcher: ClusterSystem.ActorID,
        whenTerminated nodeTerminatedFn: @escaping @Sendable (Cluster.Node) async -> Void
    ) {
        guard !self.nodeTombstones.contains(remoteNode) else {
            // the system the watcher is attempting to watch has terminated before the watch has been processed,
            // thus we have to immediately reply with a termination system message, as otherwise it would never receive one
            Task {
                await nodeTerminatedFn(remoteNode)
            }
            return
        }

        let record = WatcherAndCallback(watcherID: watcher, callback: nodeTerminatedFn)
        self.remoteWatchCallbacks[remoteNode, default: []].insert(record)
    }

    func onRemoveWatcher(
        watcherID: ClusterSystem.ActorID
    ) {
        // TODO: this can be optimized a bit more I suppose, with a reverse lookup table
        let removeMe = WatcherAndCallback(watcherID: watcherID, callback: { _ in () })
        for (node, var watcherAndCallbacks) in self.remoteWatchCallbacks {
            if watcherAndCallbacks.remove(removeMe) != nil {
                self.remoteWatchCallbacks[node] = watcherAndCallbacks
            }
        }
    }

    func onMembershipChanged(_ change: Cluster.MembershipChange) {
        guard let change = self.membership.applyMembershipChange(change) else {
            return  // no change, nothing to act on
        }

        // TODO: make sure we only handle ONCE?
        if change.status >= .down {
            // can be: down, leaving or removal.
            // on any of those we want to ensure we handle the "down"
            self.handleAddressDown(change)
        }
    }

    func handleAddressDown(_ change: Cluster.MembershipChange) {
        let terminatedNode = change.node

        // ref
        if let watchers = self.remoteWatchers.removeValue(forKey: terminatedNode) {
            for ref in watchers {
                // we notify each actor that was watching this remote address
                ref._sendSystemMessage(.nodeTerminated(terminatedNode))
            }
        }

        if let watchers = self.remoteWatchCallbacks.removeValue(forKey: terminatedNode) {
            for watcher in watchers {
                Task {
                    await watcher.callback(terminatedNode)
                }
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
    func onActorWatched(by watcher: _AddressableActorRef, remoteNode: Cluster.Node)

    /// Called when the cluster membership changes.
    ///
    /// A failure detector should signal termination signals if it notices that a previously monitored node has now
    /// left the cluster.
    // TODO: this will change to subscribing to cluster events once those land
    func onMembershipChanged(_ change: Cluster.MembershipChange)

    func onRemoveWatcher(watcherID: ClusterSystem.ActorID)
}

enum NodeDeathWatcherShell {
    typealias Ref = _ActorRef<Message>

    static var naming: _ActorNaming {
        "nodeDeathWatcher"
    }

    /// Message protocol for interacting with the failure detector.
    /// By default, the `FailureDetectorShell` handles these messages by interpreting them with an underlying `FailureDetector`,
    /// it would be possible however to allow implementing the raw protocol by user actors if we ever see the need for it.
    internal enum Message: _NotActuallyCodableMessage {
        case remoteActorWatched(watcher: _AddressableActorRef, remoteNode: Cluster.Node)
        case remoteDistributedActorWatched(remoteNode: Cluster.Node, watcherID: ClusterSystem.ActorID, nodeTerminated: @Sendable (Cluster.Node) async -> Void)
        case removeWatcher(watcherID: ClusterSystem.ActorID)
        case membershipSnapshot(Cluster.Membership)
        case membershipChange(Cluster.MembershipChange)
    }

    // FIXME: death watcher is incomplete, should handle snapshot!!
    static func behavior(clusterEvents: ClusterEventStream) -> _Behavior<Message> {
        .setup { context in
            let instance = NodeDeathWatcherInstance(selfNode: context.system.settings.bindNode)

            let onClusterEventRef = context.subReceive(Cluster.Event.self) { event in
                switch event {
                case .snapshot(let membership):
                    context.log.trace("Membership snapshot: \(membership)")
                    let diff = Cluster.Membership._diff(from: .empty, to: membership)
                    for change in diff.changes {
                        instance.onMembershipChanged(change)
                    }

                case .membershipChange(let change) where change.isAtLeast(.down):
                    context.log.trace(
                        "Node down: \(change)!",
                        metadata: [
                            "node": "\(reflecting: change.node)"
                        ]
                    )
                    instance.handleAddressDown(change)
                case .membershipChange(let change):
                    context.log.trace(
                        "Node change: \(change)!",
                        metadata: [
                            "node": "\(reflecting: change.node)"
                        ]
                    )
                    instance.onMembershipChanged(change)

                default:
                    ()  // ignore other changes, we only need to react on nodes becoming DOWN
                }
            }
            context.system.cluster.events.subscribe(onClusterEventRef)

            return NodeDeathWatcherShell.behavior(instance)
        }
    }

    static func behavior(_ instance: NodeDeathWatcherInstance) -> _Behavior<Message> {
        .receive { context, message in
            context.log.debug("Received: \(message)")
            switch message {
            case .remoteActorWatched(let watcher, let remoteNode):
                instance.onActorWatched(by: watcher, remoteNode: remoteNode)  // TODO: return and interpret directives

            case .remoteDistributedActorWatched(let remoteNode, let watcherID, let nodeTerminatedFn):
                instance.onActorWatched(on: remoteNode, by: watcherID, whenTerminated: nodeTerminatedFn)

            case .removeWatcher(let watcherID):
                instance.onRemoveWatcher(watcherID: watcherID)

            case .membershipSnapshot(let membership):
                let diff = Cluster.Membership._diff(from: .empty, to: membership)

                for change in diff.changes {
                    instance.onMembershipChanged(change)  // TODO: return and interpret directives
                }

            case .membershipChange(let change):
                instance.onMembershipChanged(change)  // TODO: return and interpret directives
            }
            return .same
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

enum NodeDeathWatcherError: Error {
    case attemptedToFailUnknownAddress(Cluster.Membership, Cluster.Node)
    case watcherActorWasNotLocal(watcherID: ActorID, localNode: Cluster.Node?)
}
