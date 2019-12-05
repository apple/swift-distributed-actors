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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Control

/// Allows controlling the cluster, e.g. by issuing join/down commands, or subscribing to cluster events.
public struct ClusterControl {
    /// Settings the cluster node is configured with.
    public let settings: ClusterSettings

    /// Read only view of the settings in use by the cluster.
    public let events: EventStream<ClusterEvent>

    internal let ref: ClusterShell.Ref

    init(_ settings: ClusterSettings, clusterRef: ClusterShell.Ref, eventStream: EventStream<ClusterEvent>) {
        self.settings = settings
        self.ref = clusterRef
        self.events = eventStream
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

    /// Mark as `MemberStatus.down` the specific `node` being passed in.
    public func down(node: UniqueNode) {
        self.ref.tell(.command(.downCommand(node.node)))
    }

    /// Mark as `MemberStatus.down` _any_ incarnation of a member matching the passed in `node`.
    ///
    /// This API is less precise than `down(node: UniqueNode)` since the latter specifies a specific incarnation of a node,
    /// meaning that given a node restarting and re-joining the cluster using the same address/port by using this down function
    /// the "new" node -- or, in other words "any incarnation of that address" -- is going to be marked down and removed from the cluster.
    /// Whereas the `UniqueNode` downing is always bound to a specific instance/incarnation of a node, and thus can be used to down
    /// a specific node, to ensure it has left the cluster, before another incarnation of it has a chance to re-join.
    public func down(node: Node) {
        self.ref.tell(.command(.downCommand(node)))
    }
}
