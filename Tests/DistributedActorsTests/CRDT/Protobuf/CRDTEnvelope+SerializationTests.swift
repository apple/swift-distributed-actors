//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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

final class CRDTEnvelopeSerializationTests: ActorSystemTestBase {
    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)

    func test_serializationOf_CRDTEnvelope_AnyDeltaCRDT_GCounter() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)
            g1.delta.shouldNotBeNil()

            let g1AsAny = g1.asAnyDeltaCRDT
            let envelope = CRDTEnvelope(serializerId: Serialization.Id.InternalSerializer.CRDTGCounter, g1AsAny)

            let bytes = try system.serialization.serialize(message: envelope)
            let deserialized = try system.serialization.deserialize(CRDTEnvelope.self, from: bytes)

            guard case .DeltaCRDT(let data) = deserialized._boxed else {
                throw self.testKit.fail("CRDTEnvelope._boxed should be .DeltaCRDT for AnyDeltaCRDT")
            }
            guard let gg1 = data.underlying as? CRDT.GCounter else {
                throw self.testKit.fail("AnyDeltaCRDT.underlying should be GCounter")
            }

            gg1.value.shouldEqual(g1.value)
            gg1.delta.shouldNotBeNil()
            "\(gg1.delta!.state)".shouldContain("[actor:sact://CRDTEnvelopeSerializationTests@localhost:9001/user/alpha: 2]")
        }
    }

    func test_serializationOf_CRDTEnvelope_AnyCvRDT_GCounter() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)
            g1.delta.shouldNotBeNil()

            let g1AsAny = g1.asAnyCvRDT
            let envelope = CRDTEnvelope(serializerId: Serialization.Id.InternalSerializer.CRDTGCounterDelta, g1AsAny)

            let bytes = try system.serialization.serialize(message: envelope)
            let deserialized = try system.serialization.deserialize(CRDTEnvelope.self, from: bytes)

            guard case .CvRDT(let data) = deserialized._boxed else {
                throw self.testKit.fail("CRDTEnvelope._boxed should be .CvRDT for AnyCvRDT")
            }
            guard let dg1 = data.underlying as? CRDT.GCounter else {
                throw self.testKit.fail("AnyCvRDT.underlying should be GCounter")
            }

            dg1.state.count.shouldEqual(1)
            "\(dg1.state)".shouldContain("[actor:sact://CRDTEnvelopeSerializationTests@localhost:9001/user/alpha: 2]")
        }
    }

    func test_serializationOf_CRDTEnvelope_AnyCvRDT_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)
            g1.delta.shouldNotBeNil()

            let g1DeltaAsAny = g1.delta!.asAnyCvRDT
            let envelope = CRDTEnvelope(serializerId: Serialization.Id.InternalSerializer.CRDTGCounterDelta, g1DeltaAsAny)

            let bytes = try system.serialization.serialize(message: envelope)
            let deserialized = try system.serialization.deserialize(CRDTEnvelope.self, from: bytes)

            guard case .CvRDT(let data) = deserialized._boxed else {
                throw self.testKit.fail("CRDTEnvelope._boxed should be .CvRDT for AnyCvRDT")
            }
            guard let dg1Delta = data.underlying as? CRDT.GCounter.Delta else {
                throw self.testKit.fail("AnyCvRDT.underlying should be GCounter.Delta")
            }

            dg1Delta.state.count.shouldEqual(1)
            "\(dg1Delta.state)".shouldContain("[actor:sact://CRDTEnvelopeSerializationTests@localhost:9001/user/alpha: 2]")
        }
    }
}
