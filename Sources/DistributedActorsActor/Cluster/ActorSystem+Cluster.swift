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

public struct ClusterControl {
    private let clusterShell: ClusterShell.Ref
    private let settings: ClusterSettings

    init(_ settings: ClusterSettings, clusterShell: ClusterShell.Ref) {
        self.settings = settings
        self.clusterShell = clusterShell
    }

    public func join(host: String, port: Int) {
        self.join(node: Node(systemName: "sact", host: host, port: port))
    }
    public func join(node: Node) {
        self.clusterShell.tell(.command(.join(node)))
    }

    public var node: UniqueNode {
        return self.settings.uniqueBindNode
    }
}

extension ActorSystem {

    public var cluster: ClusterControl {
        return .init(self.settings.cluster, clusterShell: self.clusterShell)
    }

    internal var clusterShell: ActorRef<ClusterShell.Message> {
        return self._cluster?.ref ?? self.deadLetters.adapt(from: ClusterShell.Message.self)
    }

    // TODO not sure how to best expose, but for now this is better than having to make all internal messages public.
    public func _dumpAssociations() {
        let ref: ActorRef<Set<UniqueNode>> = try! self.spawnAnonymous(.receive { context, nodes in
            let stringlyNodes = nodes.map({ String(reflecting: $0) }).joined(separator: "\n     ")
            context.log.info("~~~~ ASSOCIATED NODES ~~~~~\n     \(stringlyNodes)")
            return .stop
        })
        self.clusterShell.tell(.query(.associatedNodes(ref)))
    }

}
