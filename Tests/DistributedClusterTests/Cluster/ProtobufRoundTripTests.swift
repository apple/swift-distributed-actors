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
import NIO
import SwiftProtobuf
import XCTest

final class ProtobufRoundTripTests: SingleClusterSystemXCTestCase {
    func check<Value: _ProtobufRepresentable & Equatable>(_ value: Value) throws {
        let context = try Serialization.Context(log: self.system.log, system: self.system, allocator: self.system.serialization.allocator)
        let proto = try value.toProto(context: context)
        let back = try Value(fromProto: proto, context: context)
        back.shouldEqual(value)
    }

    let allocator = ByteBufferAllocator()
    var node: Cluster.Node {
        self.system.cluster.node
    }

    var localActorAddress: ActorID {
        try! ActorPath._user.appending("hello")
            .makeLocalID(on: self.system.cluster.node, incarnation: .wellKnown)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Core actor types

    func test_roundTrip_ActorID() throws {
        try self.check(self.localActorAddress)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake protocol

    func test_roundTrip_Wire_HandshakeOffer() throws {
        let offer = Wire.HandshakeOffer(version: .init(reserved: 2, major: 3, minor: 5, patch: 5), originNode: self.node, targetEndpoint: self.node.endpoint)
        let proto = _ProtoHandshakeOffer(offer)
        let back = try Wire.HandshakeOffer(fromProto: proto)
        back.shouldEqual(offer)
    }
}
