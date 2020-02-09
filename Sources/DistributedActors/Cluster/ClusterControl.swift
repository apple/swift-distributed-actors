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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Control

/// Allows controlling the cluster, e.g. by issuing join/down commands, or subscribing to cluster events.
public struct ClusterControl {
    /// Settings the cluster node is configured with.
    public let settings: ClusterSettings

    /// Read only view of the settings in use by the cluster.
    public let events: EventStream<Cluster.Event>

    /// Offers a snapshot of membership, which may be used to perform ad-hoc tests against the membership.
    /// Note that this view may be immediately outdated after checking if, if e.g. a membership change is just being processed.
    ///
    /// Consider subscribing to `cluster.events` in order to react to membership changes dynamically, and never miss a change.
    public var membershipSnapshot: Cluster.Membership {
        self.membershipSnapshotLock.lock()
        defer { self.membershipSnapshotLock.unlock() }
        return self._membershipSnapshotHolder.membership
    }

    internal func updateMembershipSnapshot(_ snapshot: Cluster.Membership) {
        self.membershipSnapshotLock.lock()
        defer { self.membershipSnapshotLock.unlock() }
        self._membershipSnapshotHolder.membership = snapshot
    }

    private let membershipSnapshotLock: Lock
    private let _membershipSnapshotHolder: MembershipHolder
    private class MembershipHolder {
        var membership: Cluster.Membership
        init(membership: Cluster.Membership) {
            self.membership = membership
        }
    }

    internal let ref: ClusterShell.Ref

    init(_ settings: ClusterSettings, clusterRef: ClusterShell.Ref, eventStream: EventStream<Cluster.Event>) {
        self.settings = settings
        self.ref = clusterRef
        self.events = eventStream

        let membershipSnapshotLock = Lock()
        self.membershipSnapshotLock = membershipSnapshotLock
        self._membershipSnapshotHolder = MembershipHolder(membership: .empty)
        _ = self._membershipSnapshotHolder.membership.join(settings.uniqueBindNode)
    }

    /// The node value representing _this_ node in the cluster.
    public var node: UniqueNode {
        self.settings.uniqueBindNode
    }

    public func join(host: String, port: Int) {
        self.join(node: Node(systemName: "sact", host: host, port: port))
    }

    public func join(node: Node) {
        self.ref.tell(.command(.initJoin(node)))
    }

    public func leave() {
        self.ref.tell(.command(.downCommand(self.node.node)))
    }

    /// Mark as `Cluster.MemberStatus.down` _any_ incarnation of a member matching the passed in `node`.
    public func down(node: Node) {
        self.ref.tell(.command(.downCommand(node)))
    }

    public func down(member: Cluster.Member) {
        self.ref.tell(.command(.downCommandMember(member)))
    }
}
