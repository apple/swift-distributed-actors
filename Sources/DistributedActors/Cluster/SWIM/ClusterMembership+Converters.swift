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

import ClusterMembership
import enum Dispatch.DispatchTimeInterval
import Logging
import SWIM

extension ClusterMembership.Node {
    init(uniqueNode: UniqueNode) {
        self.init(
            protocol: uniqueNode.node.protocol,
            name: uniqueNode.node.systemName,
            host: uniqueNode.host,
            port: uniqueNode.port,
            uid: uniqueNode.nid.value
        )
    }
//
//    func swimRef(_ context: _ActorContext<SWIM.Ref.Message>) -> SWIM.PeerRef {
//        context.system._resolve(context: .init(id: ._swim(on: self.asUniqueNode!), system: context.system)) // TODO: the ! is not so nice
//    }
//    
    func swimActor(_ system: ClusterSystem) -> SWIM.Actor {
        try! SWIM.Actor.resolve(id: ._swim(on: self.asUniqueNode!), using: system) // TODO: the ! is not so nice
    }

    var asUniqueNode: UniqueNode? {
        guard let uid = self.uid else {
            return nil
        }

        return .init(protocol: self.protocol, systemName: self.name ?? "", host: self.host, port: self.port, nid: .init(uid))
    }

    var asNode: DistributedActors.Node {
        .init(protocol: self.protocol, systemName: self.name ?? "", host: self.host, port: self.port)
    }
}

extension UniqueNode {
    var asSWIMNode: ClusterMembership.Node {
        .init(protocol: self.node.protocol, name: self.node.systemName, host: self.node.host, port: self.port, uid: self.nid.value)
    }
}
