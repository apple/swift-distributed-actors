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
import SWIM
import XCTest

final class SWIMSerializationTests: ActorSystemXCTestCase {
    func test_serializationOf_ping() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let payload: SWIM.GossipPayload = .membership([.init(peer: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let ping: SWIM.Message = .remote(.ping(pingOrigin: ackProbe.ref, payload: payload, sequenceNumber: 100))
        try self.shared_serializationRoundtrip(ping)
    }

    func test_serializationOf_pingRequest() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let payload: SWIM.GossipPayload = .membership([.init(peer: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.Message = .remote(.pingRequest(target: memberProbe.ref, pingRequestOrigin: ackProbe.ref, payload: payload, sequenceNumber: 100))
        try self.shared_serializationRoundtrip(pingReq)
    }

    func test_serializationOf_ack() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let payload: SWIM.GossipPayload = .membership([.init(peer: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.PingResponse = .ack(target: memberProbe.ref, incarnation: 1, payload: payload, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func test_serializationOf_nack() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let pingReq: SWIM.PingResponse = .nack(target: memberProbe.ref, sequenceNumber: 13)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func shared_serializationRoundtrip<T: ProtobufRepresentable>(_ obj: T) throws {
        let serialized = try system.serialization.serialize(obj)
        let deserialized = try system.serialization.deserialize(as: T.self, from: serialized)
        "\(obj)".shouldEqual("\(deserialized)")
    }
}
