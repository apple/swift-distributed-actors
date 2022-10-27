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

/// Implements ``LifecycleWatch`` semantics in presence of ``Cluster/Endpoint`` failures.
///
/// Depends on a failure detector (e.g. SWIM) to actually detect a node failure, however once detected,
/// it handles notifying all _local_ actors which have watched at least one actor the terminating node.
///
/// ### Implementation
/// In order to avoid every actor having to subscribe to cluster events and individually handle the relationship between those
/// and individually watched actors, the watcher handles subscribing for cluster events on behalf of actors which watch
/// other actors on remote nodes, and messages them upon a node becoming down.
///
/// Actor which is notified automatically when a remote actor is `context.watch()`-ed.
///
/// Allows manually mocking membership changes to trigger terminated notifications.
internal actor DistributedNodeDeathWatcher {
    // TODO(distributed): actually use this actor rather than the behavior

    typealias ActorSystem = ClusterSystem

    private let log: Logger

    private let selfNode: Cluster.Node
    private var membership: Cluster.Membership = .empty

    /// Members which have been `removed`
    // TODO: clear after a few days, or some max count of nodes, use sorted set for this
    private var nodeTombstones: Set<Cluster.Node> = []

    /// Mapping between remote node, and actors which have watched some actors on given remote node.
    private var remoteWatchCallbacks: [Cluster.Node: Set<WatcherAndCallback>] = [:]

    private var eventListenerTask: Task<Void, Error>?

    init(actorSystem: ActorSystem) async {
        let log = actorSystem.log
        self.log = log
        self.selfNode = actorSystem.cluster.node
        // initialized

        let events = actorSystem.cluster.events
        self.eventListenerTask = Task {
            for try await event in events {
                switch event {
                case .membershipChange(let change):
                    self.membershipChanged(change)
                case .snapshot(let membership):
                    let diff = Cluster.Membership._diff(from: .empty, to: membership)
                    for change in diff.changes {
                        self.membershipChanged(change)
                    }
                case .leadershipChange, .reachabilityChange:
                    break // ignore those, they don't affect downing
                case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
                    self.log.error("Received Cluster.Event [\(event)]. This should not happen, please file an issue.")
                }
            }
        }
    }

    func watchActor(
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

    func removeWatcher(id: ClusterSystem.ActorID) {
        // TODO: this can be optimized a bit more I suppose, with a reverse lookup table
        let removeMe = WatcherAndCallback(watcherID: id, callback: { _ in () })
        for (node, var watcherAndCallbacks) in self.remoteWatchCallbacks {
            if watcherAndCallbacks.remove(removeMe) != nil {
                self.remoteWatchCallbacks[node] = watcherAndCallbacks
            }
        }
    }

    func cleanupTombstone(node: Cluster.Node) {
        _ = self.nodeTombstones.remove(node)
    }

    func membershipChanged(_ change: Cluster.MembershipChange) {
        guard let change = self.membership.applyMembershipChange(change) else {
            return // no change, nothing to act on
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

    func cancel() {
        self.eventListenerTask?.cancel()
        self.eventListenerTask = nil
    }
}

extension DistributedNodeDeathWatcher {
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
}
