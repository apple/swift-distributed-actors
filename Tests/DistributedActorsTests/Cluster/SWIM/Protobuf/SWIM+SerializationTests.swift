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

@testable import DistributedActors
import DistributedActorsTestKit
import SWIM
import XCTest

final class SWIMSerializationTests: ClusterSystemXCTestCase {
    func test_serializationOf_ack() async throws {
        let targetNode = await setUpNode("target") { settings in
            settings.enabled = true
        }

        guard let target = targetNode._cluster?._swimShell else {
            throw testKit.fail("SWIM shell of [\(targetNode)] should not be nil")
        }

        let targetPeer = try SWIMActorShell.resolve(id: target.id._asRemote, using: self.system)
        let payload: SWIM.GossipPayload = .membership([.init(peer: targetPeer, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.PingResponse = .ack(target: targetPeer, incarnation: 1, payload: payload, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func test_serializationOf_nack() async throws {
        let targetNode = await setUpNode("target") { settings in
            settings.enabled = true
        }

        guard let target = targetNode._cluster?._swimShell else {
            throw testKit.fail("SWIM shell of [\(targetNode)] should not be nil")
        }

        let targetPeer = try SWIMActorShell.resolve(id: target.id._asRemote, using: self.system)
        let pingReq: SWIM.PingResponse = .nack(target: targetPeer, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func shared_serializationRoundtrip<T: _ProtobufRepresentable>(_ obj: T) throws {
        let serialized = try self.system.serialization.serialize(obj)
        let deserialized = try self.system.serialization.deserialize(as: T.self, from: serialized)
        "\(obj)".shouldEqual("\(deserialized)")
    }
}
