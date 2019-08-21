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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class UniqueNodeTests: XCTestCase {
    func test_uniqueNode_shouldRenderProperly() {
        let node = Node(systemName: "SystemName", host: "188.121.122.3", port: 1111)
        let uniqueNode = UniqueNode(node: node, nid: NodeID(2222))

        "\(uniqueNode)".shouldEqual("sact://SystemName@188.121.122.3:1111")
        "\(String(reflecting: uniqueNode))".shouldEqual("sact://SystemName:2222@188.121.122.3:1111")
    }

    func test_uniqueNode_comparison_equal() {
        let two = UniqueNode(node: Node(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(2222))
        let anotherTwo = two

        two.shouldEqual(anotherTwo)
        two.shouldBeLessThanOrEqual(anotherTwo)
    }

    func test_uniqueNode_comparison_lessThan() {
        let two = UniqueNode(node: Node(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(2222))
        let three = UniqueNode(node: Node(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(3333))

        two.shouldBeLessThan(three)
    }
}
