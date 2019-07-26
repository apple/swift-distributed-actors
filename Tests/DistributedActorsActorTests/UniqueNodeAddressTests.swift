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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class UniqueNodeAddressTests: XCTestCase {

    func test_uniqueNodeAddress_shouldRenderProperly() {
        let address = NodeAddress(systemName: "SystemName", host: "188.121.122.3", port: 1111)
        let uniqueAddress = UniqueNodeAddress(address: address, nid: NodeID(2222))

        "\(uniqueAddress)".shouldEqual("sact://SystemName@188.121.122.3:1111")
        "\(String(reflecting: uniqueAddress))".shouldEqual("sact://SystemName:2222@188.121.122.3:1111")
    }

    func test_uniqueNodeAddress_comparison_equal() {
        let two = UniqueNodeAddress(address: NodeAddress(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(2222))
        let anotherTwo = two

        two.shouldEqual(anotherTwo)
        two.shouldBeLessThanOrEqual(anotherTwo)
    }
    func test_uniqueNodeAddress_comparison_lessThan() {
        let two = UniqueNodeAddress(address: NodeAddress(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(2222))
        let three = UniqueNodeAddress(address: NodeAddress(systemName: "SystemName", host: "188.121.122.3", port: 1111), nid: NodeID(3333))

        two.shouldBeLessThan(three)
    }
}
