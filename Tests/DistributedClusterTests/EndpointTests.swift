//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import XCTest

final class EndpointTests: XCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Endpoint

    func test_nodes_equal_whenHostPortMatch() {
        let alpha = Cluster.Endpoint(systemName: "SystemNameAlpha", host: "111.111.11.1", port: 1111)
        let beta = Cluster.Endpoint(systemName: "SystemNameBeta", host: "111.111.11.1", port: 1111)

        // system names are only for human readability / debugging, not equality
        alpha.shouldEqual(beta)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster.Node

    func test_node_shouldRenderProperly() {
        let endpoint = Cluster.Endpoint(systemName: "SystemName", host: "188.121.122.3", port: 1111)
        let node = Cluster.Node(endpoint: endpoint, nid: Cluster.Node.ID(2222))

        "\(node)".shouldEqual("sact://SystemName@188.121.122.3:1111")
        "\(String(reflecting: node))".shouldEqual("sact://SystemName:2222@188.121.122.3:1111")
    }

    func test_node_comparison_equal() {
        let two = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: Cluster.Node.ID(2222))
        let anotherTwo = two

        two.shouldEqual(anotherTwo)
        two.shouldBeLessThanOrEqual(anotherTwo)
    }

    func test_node_comparison_lessThan() {
        let two = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: Cluster.Node.ID(2222))
        let three = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: Cluster.Node.ID(3333))

        two.shouldBeLessThan(three)
    }
}
