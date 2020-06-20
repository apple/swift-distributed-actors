//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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

final class CRDTEnvelopeSerializationTests: ActorSystemXCTestCase {
    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)

    func test_serializationOf_CRDTEnvelope_DeltaCRDTBox_GCounter() throws {
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
        g1.increment(by: 2)
        g1.delta.shouldNotBeNil()

        let g1AsAny = g1
        let envelope = CRDT.Envelope(manifest: .init(serializerID: Serialization.ReservedID.CRDTGCounter, hint: _typeName(CRDT.GCounter.self)), g1AsAny) // FIXME: real manifest

        let serialized = try system.serialization.serialize(envelope)
        let deserialized = try system.serialization.deserialize(as: CRDT.Envelope.self, from: serialized)

        guard let gg1 = deserialized.data as? CRDT.GCounter else {
            throw self.testKit.fail("DeltaCRDTBox.underlying should be GCounter")
        }

        gg1.value.shouldEqual(g1.value)
        gg1.delta.shouldNotBeNil()
        "\(gg1.delta!.state)".shouldContain("[actor:sact://CRDTEnvelopeSerializationTests@127.0.0.1:9001/user/alpha: 2]")
    }

//    // TODO: use a "real" CvRDT rather than GCounter.Delta
//    func test_serializationOf_CRDTEnvelope_AnyCvRDT_GCounter_delta() throws {
//            var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
//            g1.increment(by: 2)
//            g1.delta.shouldNotBeNil()
//
//            let g1DeltaAsAny = g1.delta!.asAnyCvRDT
//            let envelope = CRDT.Envelope(manifest: .init(serializerID: Serialization.ReservedID.CRDTGCounterDelta, hint: _typeName(CRDT.GCounterDelta.self)), g1DeltaAsAny)
//
//            var (manifest, bytes) = try system.serialization.serialize(envelope)
//            let deserialized = try system.serialization.deserialize(as: CRDT.Envelope.self, from: &bytes, using: manifest)
//
//            guard case .CvRDT(let data) = deserialized._boxed else {
//                throw self.testKit.fail("CRDT.Envelope._boxed should be .CvRDT for AnyCvRDT")
//            }
//            guard let dg1Delta = data.underlying as? CRDT.GCounter.Delta else {
//                throw self.testKit.fail("AnyCvRDT.underlying should be GCounter.Delta")
//            }
//
//            dg1Delta.state.count.shouldEqual(1)
//            "\(dg1Delta.state)".shouldContain("[actor:sact://CRDTEnvelopeSerializationTests@127.0.0.1:9001/user/alpha: 2]")
//    }
}
