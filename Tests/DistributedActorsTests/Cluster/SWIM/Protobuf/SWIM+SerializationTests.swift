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
        let target = await setUpNode("target") { settings in
            settings.enabled = true
        }

        guard let targetSwim = target._cluster?._swimShell else {
            throw testKit.fail("SWIM shell should be non nil")
        }
        let targetID = ActorID(remote: target.settings.uniqueBindNode, path: targetSwim.id.path, incarnation: targetSwim.id.incarnation)
        let targetPeer = try SWIMActorShell.resolve(id: targetID, using: self.system)

        let payload: SWIM.GossipPayload = .membership([.init(peer: targetPeer, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.PingResponse = .ack(target: targetPeer, incarnation: 1, payload: payload, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func test_serializationOf_nack() async throws {
        let target = await setUpNode("target") { settings in
            settings.enabled = true
        }

        guard let targetSwim = target._cluster?._swimShell else {
            throw testKit.fail("SWIM shell should be non nil")
        }
        let targetID = ActorID(remote: target.settings.uniqueBindNode, path: targetSwim.id.path, incarnation: targetSwim.id.incarnation)
        let targetPeer = try SWIMActorShell.resolve(id: targetID, using: self.system)

        let pingReq: SWIM.PingResponse = .nack(target: targetPeer, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func shared_serializationRoundtrip<T: _ProtobufRepresentable>(_ obj: T) throws {
        let serialized = try system.serialization.serialize(obj)
        let deserialized = try system.serialization.deserialize(as: T.self, from: serialized)
        "\(obj)".shouldEqual("\(deserialized)")
    }
}
