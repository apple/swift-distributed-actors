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

final class CRDTSerializationTests: ActorSystemTestBase {
    typealias V = UInt64

    override func setUp() {
        _ = self.setUpNode(String(describing: type(of: self))) { _ in
        }
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .wellKnown)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Identity

    func test_serializationOf_Identity() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("test-crdt")

            var (manifest, bytes) = try system.serialization.serialize(id)
            let deserialized = try system.serialization.deserialize(as: CRDT.Identity.self, from: &bytes, using: manifest)

            deserialized.id.shouldEqual("test-crdt")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.VersionContext

    func test_serializationOf_VersionContext() throws {
        try shouldNotThrow {
            let replicaAlpha = ReplicaID.actorAddress(self.ownerAlpha)
            let replicaBeta = ReplicaID.actorAddress(self.ownerBeta)

            let vv = VersionVector([(replicaAlpha, V(1)), (replicaBeta, V(3))])
            let versionContext = CRDT.VersionContext(vv: vv, gaps: [VersionDot(replicaAlpha, V(4))])

            var (manifest, bytes) = try system.serialization.serialize(versionContext)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionContext.self, from: &bytes, using: manifest)

            deserialized.vv.state.count.shouldEqual(2) // replicas alpha and beta
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 1")
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/beta: 3")

            deserialized.gaps.count.shouldEqual(1)
            "\(deserialized.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/alpha,4)")
        }
    }

    func test_serializationOf_VersionContext_empty() throws {
        try shouldNotThrow {
            let versionContext = CRDT.VersionContext()

            var (manifest, bytes) = try system.serialization.serialize(versionContext)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionContext.self, from: &bytes, using: manifest)

            deserialized.vv.isEmpty.shouldBeTrue()
            deserialized.gaps.isEmpty.shouldBeTrue()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.VersionedContainer and CRDT.VersionedContainerDelta

    func test_serializationOf_VersionedContainer_VersionedContainerDelta() throws {
        try shouldNotThrow {
            let replicaAlpha = ReplicaID.actorAddress(self.ownerAlpha)
            let replicaBeta = ReplicaID.actorAddress(self.ownerBeta)

            let vv = VersionVector([(replicaAlpha, V(2)), (replicaBeta, V(1))])
            let versionContext = CRDT.VersionContext(vv: vv, gaps: [VersionDot(replicaBeta, V(3))])
            let elementByBirthDot = [
                VersionDot(replicaAlpha, V(1)): "hello",
                VersionDot(replicaBeta, V(3)): "world",
            ]
            var versionedContainer = CRDT.VersionedContainer(replicaId: replicaAlpha, versionContext: versionContext, elementByBirthDot: elementByBirthDot)
            // Adding an element should set delta
            versionedContainer.add("bye")

            var (manifest, bytes) = try system.serialization.serialize(versionedContainer)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionedContainer<String>.self, from: &bytes, using: manifest)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 3") // adding "bye" bumps version to 3
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/beta: 1")
            "\(deserialized.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/beta,3)")
            deserialized.elementByBirthDot.count.shouldEqual(3)
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/beta,3): \"world\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/alpha,3): \"bye\"")

            deserialized.delta.shouldNotBeNil()
            // The birth dot for "bye" is added to gaps since delta's versionContext started out empty
            // and therefore not contiguous
            deserialized.delta!.versionContext.vv.isEmpty.shouldBeTrue()
            "\(deserialized.delta!.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/alpha,3)")
            deserialized.delta!.elementByBirthDot.count.shouldEqual(1)
            "\(deserialized.delta!.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:9001/user/alpha,3): \"bye\"")
        }
    }

    func test_serializationOf_VersionedContainer_empty() throws {
        try shouldNotThrow {
            let versionedContainer = CRDT.VersionedContainer<String>(replicaId: .actorAddress(ownerAlpha))

            var (manifest, bytes) = try system.serialization.serialize(versionedContainer)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionedContainer<String>.self, from: &bytes, using: manifest)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            deserialized.versionContext.vv.isEmpty.shouldBeTrue()
            deserialized.versionContext.gaps.isEmpty.shouldBeTrue()
            deserialized.elementByBirthDot.isEmpty.shouldBeTrue()
            deserialized.delta.shouldBeNil()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GCounter

    func test_serializationOf_GCounter() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)

            var (manifest, bytes) = try system.serialization.serialize(g1)
            let deserialized = try system.serialization.deserialize(as: CRDT.GCounter.self, from: &bytes, using: manifest)

            g1.value.shouldEqual(deserialized.value)
            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 2]")
        }
    }

    func test_serializationOf_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 13)

            var (manifest, bytes) = try system.serialization.serialize(g1.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(as: CRDT.GCounter.Delta.self, from: &bytes, using: manifest)

            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 13]")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORSet

    func test_serializationOf_ORSet() throws {
        try shouldNotThrow {
            var set: CRDT.ORSet<String> = CRDT.ORSet(replicaId: .actorAddress(self.ownerAlpha))
            set.add("hello") // (alpha, 1)
            set.add("world") // (alpha, 2)
            set.remove("nein")
            set.delta.shouldNotBeNil()

            var (manifest, bytes) = try system.serialization.serialize(set)
            let deserialized = try system.serialization.deserialize(as: CRDT.ORSet<String>.self, from: &bytes, using: manifest)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            deserialized.elements.shouldEqual(set.elements)
            "\(deserialized.state.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 2]")
            deserialized.state.versionContext.gaps.isEmpty.shouldBeTrue() // changes are contiguous so no gaps
            deserialized.state.elementByBirthDot.count.shouldEqual(2)
            "\(deserialized.state.elementByBirthDot)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized.state.elementByBirthDot)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right

            deserialized.delta.shouldNotBeNil()
            deserialized.delta!.elementByBirthDot.count.shouldEqual(set.delta!.elementByBirthDot.count) // same elements added to delta
        }
    }

    func test_serializationOf_ORSet_delta() throws {
        try shouldNotThrow {
            var set: CRDT.ORSet<String> = CRDT.ORSet(replicaId: .actorAddress(self.ownerAlpha))
            set.add("hello") // (alpha, 1)
            set.add("world") // (alpha, 2)
            set.remove("nein")

            var (manifest, bytes) = try system.serialization.serialize(set.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(as: CRDT.ORSet<String>.Delta.self, from: &bytes, using: manifest)

            // delta contains the same elements as set
            "\(deserialized.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 2]")
            deserialized.versionContext.gaps.isEmpty.shouldBeTrue() // changes are contiguous so no gaps
            deserialized.elementByBirthDot.count.shouldEqual(2)
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right
        }
    }
}
