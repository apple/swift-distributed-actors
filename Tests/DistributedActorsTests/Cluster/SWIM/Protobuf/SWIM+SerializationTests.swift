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
import XCTest

final class SWIMSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_serializationOf_ping() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let payload: SWIM.Payload = .membership([.init(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let ping: SWIM.Message = .remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: payload))
        try self.shared_serializationRoundtrip(ping)
    }

    func test_serializationOf_pingReq() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let payload: SWIM.Payload = .membership([.init(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.Message = .remote(.pingReq(target: memberProbe.ref, lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: payload))
        try self.shared_serializationRoundtrip(pingReq)
    }

    func test_serializationOf_Ack() throws {
        let memberProbe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let payload: SWIM.Payload = .membership([.init(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])
        let pingReq: SWIM.Ack = .init(pinged: memberProbe.ref, incarnation: 1, payload: payload)
        try self.shared_serializationRoundtrip(pingReq)
    }

    func shared_serializationRoundtrip<T: InternalProtobufRepresentable>(_ obj: T) throws {
        let bytes = try system.serialization.serialize(message: obj)
        let deserialized = try system.serialization.deserialize(T.self, from: bytes)
        "\(obj)".shouldEqual("\(deserialized)")
    }
}
