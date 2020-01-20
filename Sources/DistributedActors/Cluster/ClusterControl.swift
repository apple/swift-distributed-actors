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
    public let events: EventStream<Cluster.Event>

    internal let ref: ClusterShell.Ref

    init(_ settings: ClusterSettings, clusterRef: ClusterShell.Ref, eventStream: EventStream<Cluster.Event>) {
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

//    func leave() {
//        // issue a .leaving and then ensure everyone has seen it, then become down
//    }

    /// Mark as `Cluster.MemberStatus.down` _any_ incarnation of a member matching the passed in `node`.
    public func down(node: Node) {
        self.ref.tell(.command(.downCommand(node)))
    }
}
