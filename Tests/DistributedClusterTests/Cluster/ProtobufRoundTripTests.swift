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

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import NIO
import SwiftProtobuf
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ProtobufRoundTripTests {
    func check<Value: _ProtobufRepresentable & Equatable>(_ value: Value) throws {
        let context = self.testCase.context
        let proto = try value.toProto(context: context)
        let back = try Value(fromProto: proto, context: context)
        back.shouldEqual(value)
    }

    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Core actor types
    @Test
    func test_roundTrip_ActorID() throws {
        try self.check(self.self.testCase.localActorAddress)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake protocol
    @Test
    func test_roundTrip_Wire_HandshakeOffer() throws {
        let node = self.self.testCase.node
        let offer = Wire.HandshakeOffer(
            version: .init(reserved: 2, major: 3, minor: 5, patch: 5),
            originNode: node,
            targetEndpoint: node.endpoint
        )
        let proto = _ProtoHandshakeOffer(offer)
        let back = try Wire.HandshakeOffer(fromProto: proto)
        back.shouldEqual(offer)
    }
}

extension SingleClusterSystemTestCase {
    
    var node: Cluster.Node {
        self.system.cluster.node
    }
    
    var localActorAddress: ActorID {
        try! ActorPath._user.appending("hello")
            .makeLocalID(on: self.system.cluster.node, incarnation: .wellKnown)
    }
}
