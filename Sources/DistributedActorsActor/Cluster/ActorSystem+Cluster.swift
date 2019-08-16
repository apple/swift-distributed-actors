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

import NIO
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Control

/// Allows controlling the cluster, e.g. by issuing join/down commands, or subscribing to cluster events.
public struct ClusterControl {
    /// Read only view of the settings in use by the cluster.
    public let events: EventStream<ClusterEvent>
    
    public let settings: ClusterSettings

    internal let _shell: ClusterShell.Ref

    init(_ settings: ClusterSettings, shell: ClusterShell.Ref, eventStream: EventStream<ClusterEvent>) {
        self.settings = settings
        self._shell = shell
        self.events = eventStream
    }

    public func join(host: String, port: Int) {
        self.join(node: Node(systemName: "sact", host: host, port: port))
    }
    public func join(node: Node) {
        self._shell.tell(.command(.join(node)))
    }

    public func down(node: Node) {
        self._shell.tell(.command(.downCommand(node)))
    }
    public func down(node: UniqueNode) {
        self._shell.tell(.command(.downCommand(node.node)))
    }

    public var node: UniqueNode {
        return self.settings.uniqueBindNode
    }
}

extension ActorSystem {

    public var cluster: ClusterControl {
        let shell = self._cluster?.ref ?? self.deadLetters.adapted()
        return .init(self.settings.cluster, shell: shell, eventStream: self.clusterEvents)
    }

    internal var clusterEvents: EventStream<ClusterEvent> {
        return self._clusterEventStream ?? EventStream(ref: self.deadLetters.adapted())
    }

}

