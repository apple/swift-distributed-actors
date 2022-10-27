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
    init(node: Cluster.Node) {
        self.init(
            protocol: node.endpoint.protocol,
            name: node.endpoint.systemName,
            host: node.host,
            port: node.port,
            uid: node.nid.value
        )
    }

    func swimShell(_ system: ClusterSystem) -> SWIMActor {
        try! SWIMActor.resolve(id: ._swim(on: self.asClusterNode!), using: system) // TODO: the ! is not so nice
    }

    var asClusterNode: Cluster.Node? {
        guard let uid = self.uid else {
            return nil
        }

        return .init(protocol: self.protocol, systemName: self.name ?? "", host: self.host, port: self.port, nid: .init(uid))
    }

    var asNode: DistributedCluster.Cluster.Endpoint {
        .init(protocol: self.protocol, systemName: self.name ?? "", host: self.host, port: self.port)
    }
}

extension Cluster.Node {
    var asSWIMNode: ClusterMembership.Node {
        .init(protocol: self.endpoint.protocol, name: self.endpoint.systemName, host: self.endpoint.host, port: self.port, uid: self.nid.value)
    }
}
