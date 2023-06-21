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
    public let events: ClusterEventStream

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
    }

    private let cluster: ClusterShell?
    internal let ref: ClusterShell.Ref

    init(_ settings: ClusterSystemSettings, cluster: ClusterShell?, clusterRef: ClusterShell.Ref, eventStream: ClusterEventStream) {
        self.settings = settings
        self.cluster = cluster
        self.ref = clusterRef
        self.events = eventStream

        var initialMembership: Cluster.Membership = .empty
        _ = initialMembership.join(settings.bindNode)
        self._membershipSnapshotHolder = ClusterControl.MembershipHolder(membership: initialMembership)
    }

    /// The node value representing _this_ node in the cluster.
    public var node: Cluster.Node {
        self.settings.bindNode
    }

    /// The endpoint value representing _this_ node in the cluster.
    public var endpoint: Cluster.Endpoint {
        self.node.endpoint
    }

    /// The member representing _this_ node in the cluster.
    ///
    /// Its ``MemberStatus`` is based on the current membership snapshot, so if changes are happening to the membership
    /// beware that this view may be out of date and it may be useful to observe a stream of cluster events if you
    /// intend to use the member long-term. Specifically, it is not advised to store a member for long term use purposes,
    /// exactly because its status may be changing over time -- subscribe to the cluster event stream instead, or always
    /// query the ``membershipSnapshot`` instead in such situations.
    public var member: Cluster.Member {
        get async {
            let membership = await membershipSnapshot
            guard let member = membership.member(self.node) else {
                fatalError("Unexpected: self.membership must always contain member for the current node, but didn't! Node: \(self.node), membership: \(membership)")
            }

            return member
        }
    }

    /// Instructs the cluster to join the actor system located listening on the passed in host-port pair.
    ///
    /// There is no specific need to "wait until joined" before one can attempt to send to references located on the cluster member,
    /// as message sends will be buffered until the node associates and joins.
    public func join(host: String, port: Int) {
        self.join(endpoint: Cluster.Endpoint(systemName: "sact", host: host, port: port))
    }

    /// Instructs the cluster to join the actor system located listening on the passed in host-port pair.
    ///
    /// There is no specific need to "wait until joined" before one can attempt to send to references located on the cluster member,
    /// as message sends will be buffered until the node associates and joins.
    public func join(endpoint: Cluster.Endpoint) {
        self.ref.tell(.command(.handshakeWith(endpoint)))
    }

    /// Usually not to be used, as having an instance of a `Cluster.Node` in hand
    /// is normally only possible after a handshake with the remote node has completed.
    ///
    /// However, in local testing scenarios, where the two nodes are executing in the same process (e.g. in a test),
    /// this call saves the unwrapping of `cluster.node` into the generic node when joining them.
    ///
    /// - Parameter node: The node to be joined by this system.
    public func join(node: Cluster.Node) {
        self.join(endpoint: node.endpoint)
    }

    /// Gracefully
    public func leave() {
        self.ref.tell(.command(.downCommand(self.node.endpoint)))
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
    public func down(endpoint: Cluster.Endpoint) {
        self.ref.tell(.command(.downCommand(endpoint)))
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

    /// Wait, within the given duration, until this actor system has joined the cluster and become ``Cluster/MemberStatus/up``.
    ///
    /// - Parameters
    ///   - node: The node to be joined by this system.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node.
    @discardableResult
    public func joined(within: Duration) async throws -> Cluster.Member {
        try await self.waitFor(self.node, .up, within: within)
    }

    /// Wait, within the given duration, until the passed in node has joined the cluster and become ``Cluster/MemberStatus/up``.
    ///
    /// - Parameters
    ///   - node: The node to be joined by this system.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node.
    @discardableResult
    public func joined(node: Cluster.Node, within: Duration) async throws -> Cluster.Member {
        try await self.waitFor(node, .up, within: within)
    }

    /// Wait, within the given duration, until the passed in node has joined the cluster and become ``Cluster/MemberStatus/up``.
    ///
    /// - Parameters
    ///   - endpoint: The endpoint to be joined by this system.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node.
    @discardableResult
    public func joined(endpoint: Cluster.Endpoint, within: Duration) async throws -> Cluster.Member? {
        try await self.waitFor(self.node, .up, within: within)
    }

    /// Wait, within the given duration, for this actor system to be a member of all the nodes' respective cluster and have the specified status.
    ///
    /// - Parameters
    ///   - nodes: The nodes to be joined by this system.
    ///   - status: The expected member status.
    ///   - within: Duration to wait for.
    public func waitFor(_ nodes: some Collection<Cluster.Node>, _ status: Cluster.MemberStatus, within: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    try await self.waitFor(node, status, within: within)
                }
            }
            // loop explicitly to propagate any error that might have been thrown
            for try await _ in group {}
        }
    }

    /// Wait, within the given duration, for this actor system to be a member of all the nodes' respective cluster and have **at least** the specified status.
    ///
    /// - Parameters
    ///   - nodes: The nodes to be joined by this system.
    ///   - atLeastStatus: The minimum expected member status.
    ///   - within: Duration to wait for.
    public func waitFor(_ nodes: some Collection<Cluster.Node>, atLeast atLeastStatus: Cluster.MemberStatus, within: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    _ = try await self.waitFor(node, atLeast: atLeastStatus, within: within)
                }
            }
            // loop explicitly to propagate any error that might have been thrown
            for try await _ in group {}
        }
    }

    /// Wait, within the given duration, for this actor system to be a member of the node's cluster and have the specified status.
    ///
    /// - Parameters
    ///   - node: The node to be joined by this system.
    ///   - status: The expected member status.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node with the expected status.
    ///         If the expected status is `.down` or `.removed`, and the node is already known to have been removed from the cluster
    ///         a synthesized `Cluster/MemberStatus/removed` (and `.unreachable`) member is returned.
    @discardableResult
    public func waitFor(_ node: Cluster.Node, _ status: Cluster.MemberStatus, within: Duration) async throws -> Cluster.Member {
        try await self.waitForMembershipEventually(within: within) { membership in
            if status == .down || status == .removed {
                if let cluster = self.cluster, cluster.getExistingAssociationTombstone(with: node) != nil {
                    return Cluster.Member(node: node, status: .removed).asUnreachable
                }
            }

            guard let foundMember = membership.member(node) else {
                if status == .down || status == .removed {
                    // so we're seeing an already removed member, this can indeed happen and is okey
                    return Cluster.Member(node: node, status: .removed).asUnreachable
                }
                throw Cluster.MembershipError(.notFound(node, in: membership))
            }

            if status != foundMember.status {
                throw Cluster.MembershipError(.statusRequirementNotMet(expected: status, found: foundMember))
            }
            return foundMember
        }
    }

    /// Wait, within the given duration, for this actor system to be a member of the node's cluster and have the specified status.
    ///
    /// - Parameters
    ///   - endpoint: The endpoint to be joined by this system.
    ///   - status: The expected member status.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node with the expected status.
    ///         If the expected status is `.down` or `.removed`, and the node is already known to have been removed from the cluster
    ///         a synthesized `Cluster/MemberStatus/removed` (and `.unreachable`) member is returned.
    @discardableResult
    public func waitFor(_ endpoint: Cluster.Endpoint, _ status: Cluster.MemberStatus, within: Duration) async throws -> Cluster.Member? {
        try await self.waitForMembershipEventually(Cluster.Member?.self, within: within) { membership in
            guard let foundMember = membership.anyMember(forEndpoint: endpoint) else {
                if status == .down || status == .removed {
                    return nil
                }
                throw Cluster.MembershipError(.notFoundAny(endpoint, in: membership))
            }

            if status != foundMember.status {
                throw Cluster.MembershipError(.statusRequirementNotMet(expected: status, found: foundMember))
            }
            return foundMember
        }
    }

    /// Wait, within the given duration, for this actor system to be a member of the node's cluster and have **at least** the specified status.
    ///
    /// - Parameters
    ///   - node: The node to be joined by this system.
    ///   - atLeastStatus: The minimum expected member status.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node with the minimum expected status.
    ///         If the expected status is at least `.down` or `.removed`, and either a tombstone exists for the node or the associated
    ///         membership is not found, the `Cluster.Member` returned would have `.removed` status and *unreachable*.
    @discardableResult
    public func waitFor(_ node: Cluster.Node, atLeast atLeastStatus: Cluster.MemberStatus, within: Duration) async throws -> Cluster.Member {
        try await self.waitForMembershipEventually(within: within) { membership in
            if atLeastStatus == .down || atLeastStatus == .removed {
                if let cluster = self.cluster, cluster.getExistingAssociationTombstone(with: node) != nil {
                    return Cluster.Member(node: node, status: .removed).asUnreachable
                }
            }

            guard let foundMember = membership.member(node) else {
                if atLeastStatus == .down || atLeastStatus == .removed {
                    // so we're seeing an already removed member, this can indeed happen and is okey
                    return Cluster.Member(node: node, status: .removed).asUnreachable
                }
                throw Cluster.MembershipError(.notFound(node, in: membership))
            }

            if atLeastStatus <= foundMember.status {
                throw Cluster.MembershipError(.atLeastStatusRequirementNotMet(expectedAtLeast: atLeastStatus, found: foundMember))
            }
            return foundMember
        }
    }

    /// Perform a **local change** to the membership such that the leader of the cluster is assumed to be `member`.
    ///
    /// In order to implement various leader election mechanisms, users are free to choose whichever mechanism
    /// suits them: rely on an external system, implement a leader election
    ///
    /// > NOTE: This change is NOT applied to other nodes via gossip./
    ///
    /// If there are any pending leader actions stashed on the new leader (such as downing nodes),
    /// they will be executed as soon as it becomes the leader.
    ///
    /// If the passed in event applied to the current membership is an effective change,
    /// the change will be published using the `system.cluster.events`. On the contrary, if the change either was
    /// already caused independently, or of the target leader already is the leader, no new event will be emitted.
    ///
    /// - Parameter member: the change to apply to the cluster.
    public func assumeLeader(_ member: Cluster.Member) {
        // old leader does not matter for applying this change, we assume the new leader based on external decisions.
        guard let change = Cluster.LeadershipChange(oldLeader: nil, newLeader: member) else {
            fatalError("Impossible that leadership change would be ineffective when moving from 'nil' to: \(member)")
        }
        self.ref.tell(.requestMembershipChange(.leadershipChange(change)))
    }

    /// Wait, within the given duration, for a leader to be found in the cluster membership and have **at least** the specified status.
    ///
    /// - Parameters
    ///   - node: The node to be joined by this system.
    ///   - atLeastStatus: The minimum expected member status.
    ///   - within: Duration to wait for.
    ///
    /// - Returns `Cluster.Member` for the joined node with the minimum expected status.
    ///         If the expected status is at least `.down` or `.removed`, and either a tombstone exists for the node or the associated
    ///         membership is not found, the `Cluster.Member` returned would have `.removed` status and *unreachable*.
    @discardableResult
    public func waitForLeader(atLeast atLeastStatus: Cluster.MemberStatus, within: Duration, file: String = #fileID, line: UInt = #line) async throws -> Cluster.Member? {
        try await self.waitForMembershipEventually(Cluster.Member?.self, within: within, file: file, line: line) { membership in
            guard let foundLeader = membership.leader else {
                if atLeastStatus == .down || atLeastStatus == .removed {
                    return nil
                }
                throw Cluster.MembershipError(.notFoundAny(endpoint, in: membership), file: file, line: line)
            }

            guard foundLeader.status >= atLeastStatus else {
                throw Cluster.MembershipError(.atLeastStatusRequirementNotMet(expectedAtLeast: atLeastStatus, found: foundLeader), file: file, line: line)
            }
            return foundLeader
        }
    }

    /// Wait, within the given duration, for this node to become a leader of the cluster.
    @discardableResult
    public func waitToBecomeLeader(file: String = #fileID, line: UInt = #line) async throws -> Cluster.Member {
        for await event in self.events {
            switch event {
            case .leadershipChange(let leaderChanged):
                guard let newLeader = leaderChanged.newLeader else {
                    continue // keep waiting
                }
                guard newLeader.node == self.node else {
                    continue // keep waiting, someone else has become leader
                }
                return newLeader // yay, we have become the leader!

            case .membershipChange(let change):
                guard change.member.node == self.node else {
                    // change about some other node, we're not concerned about those here
                    continue
                }
                if change.member.status.isDown || change.member.status.isRemoved {
                    // If we became down, we'll never become leader
                    throw Cluster.MembershipError(.statusRequirementNotMet(expected: .joining, found: change.member))
                }
                continue

            case .snapshot(let snapshot):
                guard let member = snapshot.member(self.node) else {
                    continue
                }
                if member.status.isDown || member.status.isRemoved {
                    // If we became down, we'll never become leader
                    throw Cluster.MembershipError(.statusRequirementNotMet(expected: .joining, found: member))
                }
                continue

            default:
                continue
            }
        }

        /// We broke out of looking at the events before becoming the leader, throe that we didn't find "it";
        /// This likely would happen if the task running the wait method would have been cancelled.
        if Task.isCancelled {
            throw CancellationError()
        }

        throw await Cluster.MembershipError(.notFound(self.node, in: self.membershipSnapshot))
    }

    private func waitForMembershipEventually<T>(_: T.Type = T.self,
                                                within: Duration,
                                                interval: Duration = .milliseconds(100),
                                                file: String = #fileID, line: UInt = #line,
                                                _ block: (Cluster.Membership) async throws -> T) async throws -> T
    {
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

        throw Cluster.MembershipError(.awaitStatusTimedOut(within, lastError), file: file, line: line)
    }
}
