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
import NIO
import SwiftProtobuf
import XCTest

final class ProtobufRoundTripTests: ActorSystemXCTestCase {
    func check<Value>(_ value: Value) throws {
        let serialized = try self.system.serialization.serialize(value)
        let back = try self.system.serialization.deserialize(as: Value.self, from: serialized)
        "\(back)".shouldEqual("\(value)")
    }

    let allocator = ByteBufferAllocator()
    let node = UniqueNode(node: Node(systemName: "system", host: "127.0.0.1", port: 8888), nid: .random())
    let otherNode = UniqueNode(node: Node(systemName: "system", host: "888.0.0.1", port: 9999), nid: .random())

    var localActorAddress: ActorAddress {
        try! ActorPath._user.appending("hello")
            .makeLocalAddress(on: .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random()), incarnation: .wellKnown)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Core actor types

    func test_roundTrip_ActorAddress() throws {
        try self.check(self.localActorAddress)
    }

    func test_roundTrip_ActorPath() throws {
        try self.check(ActorPath._user.appending("hello").appending("more").appending("another"))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake protocol

    func test_roundTrip_Wire_HandshakeOffer() throws {
        try self.check(Wire.HandshakeOffer(version: .init(reserved: 2, major: 3, minor: 5, patch: 5), originNode: self.node, targetNode: self.node.node))
    }
}
