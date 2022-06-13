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
import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Control

/// Allows controlling the cluster, e.g. by issuing join/down commands, or subscribing to cluster events.
public struct ClusterControl {
    /// Settings the cluster node is configured with.
    public let settings: ClusterSystemSettings

    /// Sequence of cluster events.
    ///
    /// This sequence begins with a snapshot of the current cluster state and continues with events representing changes
    /// since the snapshot.
    public let events: EventStream<Cluster.Event>

    /// Offers a snapshot of membership, which may be used to perform ad-hoc tests against the membership.
    /// Note that this view may be immediately outdated after checking if, if e.g. a membership change is just being processed.
    ///
    /// Consider subscribing to `cluster.events` in order to react to membership changes dynamically, and never miss a change.
    ///
    /// It is guaranteed that a `membershipSnapshot` is always at-least as up-to-date as an emitted ``Cluster/Event``.
    /// It may be "ahead" however, for example if a series of 3 events are published closely one after another,
    /// if one were to observe the `cluster.membershipSnapshot` when receiving the first event, it may already contain
    /// information related to the next two incoming events. For that reason is recommended to stick to one of the ways
    /// of obtaining the information to act on rather than mixing the two. Use events if transitions state should trigger
    /// something, and use the snapshot for ad-hoc "one time" membership inspections.
    public var membershipSnapshot: Cluster.Membership {
        get async {
            await self._membershipSnapshotHolder.membership
        }
    }

    internal func updateMembershipSnapshot(_ snapshot: Cluster.Membership) {
        Task {
            await self._membershipSnapshotHolder.update(snapshot)
        }
    }

    private let _membershipSnapshotHolder: MembershipHolder
    private actor MembershipHolder {
        var membership: Cluster.Membership

        init(membership: Cluster.Membership) {
            self.membership = membership
        }

        func update(_ membership: Cluster.Membership) {
            self.membership = membership
        }

        func join(_ node: UniqueNode) {
            _ = self.membership.join(node)
        }
    }

    internal let ref: ClusterShell.Ref

    init(_ settings: ClusterSystemSettings, clusterRef: ClusterShell.Ref, eventStream: EventStream<Cluster.Event>) {
        self.settings = settings
        self.ref = clusterRef
        self.events = eventStream

        let membershipHolder = ClusterControl.MembershipHolder(membership: .empty)
        self._membershipSnapshotHolder = membershipHolder
        Task {
            await membershipHolder.join(settings.uniqueBindNode)
        }
    }

    /// The node value representing _this_ node in the cluster.
    public var uniqueNode: UniqueNode {
        self.settings.uniqueBindNode
    }

    /// Instructs the cluster to join the actor system located listening on the passed in host-port pair.
    ///
    /// There is no specific need to "wait until joined" before one can attempt to send to references located on the cluster member,
    /// as message sends will be buffered until the node associates and joins.
    public func join(host: String, port: Int) {
        self.join(node: Node(systemName: "sact", host: host, port: port))
    }

    /// Instructs the cluster to join the actor system located listening on the passed in host-port pair.
    ///
    /// There is no specific need to "wait until joined" before one can attempt to send to references located on the cluster member,
    /// as message sends will be buffered until the node associates and joins.
    public func join(node: Node) {
        self.ref.tell(.command(.handshakeWith(node)))
    }

    /// Usually not to be used, as having an instance of a `UniqueNode` in hand
    /// is normally only possible after a handshake with the remote node has completed.
    ///
    /// However, in local testing scenarios, where the two nodes are executing in the same process (e.g. in a test),
    /// this call saves the unwrapping of `cluster.node` into the generic node when joining them.
    ///
    /// - Parameter node: The node to be joined by this system.
    public func join(node: UniqueNode) {
        self.join(node: node.node)
    }

    /// Gracefully
    ///
    // TODO: no graceful steps implemented today yet) leave the cluster.
    // TODO: leave should perhaps return a future or something to await on.
    public func leave() {
        self.ref.tell(.command(.downCommand(self.uniqueNode.node)))
    }

    /// Mark *any* currently known member as ``Cluster/MemberStatus/down``.
    ///
    /// Beware that this API is not very precise and, if possible, the `down(Cluster.Member)` is preferred, as it indicates
    /// the downing intent of a *specific* actor system instance, rather than any system running on the given host-port pair.
    ///
    /// This action can be performed by any member of the cluster and is immediately effective locally, as well as spread
    /// to other cluster members which will accept is as truth (even if they cal still reach the member and consider it as `.up` etc).
    ///
    /// Note that once all members have seen the downed node as `.down` it will be completely *removed* from the membership
    /// and a tombstone will be stored to prevent it from ever "re-joining" the same cluster. New instances on the same host-port
    /// pair however are accepted to join the cluster (though technically this is a newly joining node, not really a "re-join").
    ///
    /// - SeeAlso: `Cluster.MemberStatus` for more discussion about what the `.down` status implies.
    public func down(node: Node) {
        self.ref.tell(.command(.downCommand(node)))
    }

    /// Mark the passed in `Cluster.Member` as `Cluster.MemberStatus` `.down`.
    ///
    /// This action can be performed by any member of the cluster and is immediately effective locally, as well as spread
    /// to other cluster members which will accept is as truth (even if they cal still reach the member and consider it as `.up` etc).
    ///
    /// Note that once all members have seen the downed node as `.down` it will be completely *removed* from the membership
    /// and a tombstone will be stored to prevent it from ever "re-joining" the same cluster. New instances on the same host-port
    /// pair however are accepted to join the cluster (though technically this is a newly joining node, not really a "re-join").
    ///
    /// - SeeAlso: `Cluster.MemberStatus` for more discussion about what the `.down` status implies.
    public func down(member: Cluster.Member) {
        self.ref.tell(.command(.downCommandMember(member)))
    }

    public func joined(node: UniqueNode, within: Duration) async throws -> Cluster.Member {
        try await self.awaitMemberStatus(is: .up, within: within, node: node)
    }

    public func waitFor(nodes: Set<UniqueNode>, _ status: Cluster.MemberStatus, within: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    _ = try await self.awaitMemberStatus(is: status, within: within, node: node)
                }
                try await group.next() // this is required to propagate error and cancel all tasks
            }
        }
    }

    public func waitFor(nodes: Set<UniqueNode>, atLeast atLeastStatus: Cluster.MemberStatus, within: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    _ = try await self.awaitMemberStatus(atLeast: atLeastStatus, within: within, node: node)
                }
                try await group.next() // this is required to propagate error and cancel all tasks
            }
        }
    }
    
    public func awaitMemberStatus(is status: Cluster.MemberStatus, within: Duration, node: UniqueNode) async throws -> Cluster.Member {
        try await self.awaitMemberStatusEventually(within: within) { membership in
            guard let foundMember = membership.uniqueMember(node) else {
                throw Cluster.MembershipError.notFound(node)
            }

            if status != foundMember.status {
                throw Cluster.MembershipError.statusRequirementNotMet(expected: status, actual: foundMember.status)
            }
            return foundMember
        }
    }

    public func awaitMemberStatus(atLeast atLeastStatus: Cluster.MemberStatus, within: Duration, node: UniqueNode) async throws -> Cluster.Member? {
        try await self.awaitMemberStatusEventually(within: within) { membership in
            guard let foundMember = membership.uniqueMember(node) else {
                if atLeastStatus == .down || atLeastStatus == .removed {
                    // so we're seeing an already removed member, this can indeed happen and is okey
                    return nil
                } else {
                    throw Cluster.MembershipError.notFound(node)
                }
            }

            if atLeastStatus <= foundMember.status {
                throw Cluster.MembershipError.atLeastStatusRequirementNotMet(expectedAtLeast: atLeastStatus, actual: foundMember.status)
            }
            return foundMember
        }
    }

    private func awaitMemberStatusEventually<T>(within: Duration, interval: Duration = .milliseconds(100), _ block: (Cluster.Membership) async throws -> T) async throws -> T {
        let deadline = ContinuousClock.Instant.fromNow(within)

        var lastError: Error?
        while deadline.hasTimeLeft() {
            let membership = await self.membershipSnapshot
            do {
                let result = try await block(membership)
                return result
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(interval.nanoseconds))
            }
        }

        throw Cluster.MembershipError.awaitStatusTimedOut(within, lastError)
    }
}
