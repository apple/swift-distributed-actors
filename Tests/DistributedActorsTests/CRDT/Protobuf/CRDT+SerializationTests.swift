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

final class CRDTSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerProtobufRepresentable(for: CRDT.Identity.self, underId: 1001)
            settings.serialization.registerProtobufRepresentable(for: CRDT.VersionContext.self, underId: 1002)
            settings.serialization.registerProtobufRepresentable(for: CRDT.VersionedContainer<String>.self, underId: 1003)
            settings.serialization.registerProtobufRepresentable(for: CRDT.VersionedContainerDelta<String>.self, underId: 1004)
            settings.serialization.registerProtobufRepresentable(for: CRDT.ORSet<String>.self, underId: 1005)
            // CRDT.ORSet<String>.Delta is the same as CRDT.VersionedContainerDelta<String> (id: 1004)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Identity

    func test_serializationOf_Identity() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("test-crdt")

            let bytes = try system.serialization.serialize(message: id)
            let deserialized = try system.serialization.deserialize(CRDT.Identity.self, from: bytes)

            deserialized.id.shouldEqual("test-crdt")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.VersionContext

    func test_serializationOf_VersionContext() throws {
        try shouldNotThrow {
            let replicaAlpha = ReplicaId.actorAddress(self.ownerAlpha)
            let replicaBeta = ReplicaId.actorAddress(self.ownerBeta)

            let vv = VersionVector([(replicaAlpha, 1), (replicaBeta, 3)])
            let versionContext = CRDT.VersionContext(vv: vv, gaps: [VersionDot(replicaAlpha, 4)])

            let bytes = try system.serialization.serialize(message: versionContext)
            let deserialized = try system.serialization.deserialize(CRDT.VersionContext.self, from: bytes)

            deserialized.vv.state.count.shouldEqual(2) // replicas alpha and beta
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 1")
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/beta: 3")

            deserialized.gaps.count.shouldEqual(1)
            "\(deserialized.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/alpha,4)")
        }
    }

    func test_serializationOf_VersionContext_empty() throws {
        try shouldNotThrow {
            let versionContext = CRDT.VersionContext()

            let bytes = try system.serialization.serialize(message: versionContext)
            let deserialized = try system.serialization.deserialize(CRDT.VersionContext.self, from: bytes)

            deserialized.vv.isEmpty.shouldBeTrue()
            deserialized.gaps.isEmpty.shouldBeTrue()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.VersionedContainer and CRDT.VersionedContainerDelta

    func test_serializationOf_VersionedContainer_VersionedContainerDelta() throws {
        try shouldNotThrow {
            let replicaAlpha = ReplicaId.actorAddress(self.ownerAlpha)
            let replicaBeta = ReplicaId.actorAddress(self.ownerBeta)

            let vv = VersionVector([(replicaAlpha, 2), (replicaBeta, 1)])
            let versionContext = CRDT.VersionContext(vv: vv, gaps: [VersionDot(replicaBeta, 3)])
            let elementByBirthDot = [
                VersionDot(replicaAlpha, 1): "hello",
                VersionDot(replicaBeta, 3): "world",
            ]
            var versionedContainer = CRDT.VersionedContainer(replicaId: replicaAlpha, versionContext: versionContext, elementByBirthDot: elementByBirthDot)
            // Adding an element should set delta
            versionedContainer.add("bye")

            let bytes = try system.serialization.serialize(message: versionedContainer)
            let deserialized = try system.serialization.deserialize(CRDT.VersionedContainer<String>.self, from: bytes)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha")
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 3") // adding "bye" bumps version to 3
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/beta: 1")
            "\(deserialized.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/beta,3)")
            deserialized.elementByBirthDot.count.shouldEqual(3)
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/beta,3): \"world\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/alpha,3): \"bye\"")

            deserialized.delta.shouldNotBeNil()
            // The birth dot for "bye" is added to gaps since delta's versionContext started out empty
            // and therefore not contiguous
            deserialized.delta!.versionContext.vv.isEmpty.shouldBeTrue()
            "\(deserialized.delta!.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/alpha,3)")
            deserialized.delta!.elementByBirthDot.count.shouldEqual(1)
            "\(deserialized.delta!.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@localhost:7337/user/alpha,3): \"bye\"")
        }
    }

    func test_serializationOf_VersionedContainer_empty() throws {
        try shouldNotThrow {
            let versionedContainer = CRDT.VersionedContainer<String>(replicaId: .actorAddress(ownerAlpha))

            let bytes = try system.serialization.serialize(message: versionedContainer)
            let deserialized = try system.serialization.deserialize(CRDT.VersionedContainer<String>.self, from: bytes)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha")
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

            let bytes = try system.serialization.serialize(message: g1)
            let deserialized = try system.serialization.deserialize(CRDT.GCounter.self, from: bytes)

            g1.value.shouldEqual(deserialized.value)
            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha")
            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 2]")
        }
    }

    func test_serializationOf_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 13)

            let bytes = try system.serialization.serialize(message: g1.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(CRDT.GCounter.Delta.self, from: bytes)

            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 13]")
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

            let bytes = try system.serialization.serialize(message: set)
            let deserialized = try system.serialization.deserialize(CRDT.ORSet<String>.self, from: bytes)

            "\(deserialized.replicaId)".shouldContain("actor:sact://CRDTSerializationTests@localhost:7337/user/alpha")
            deserialized.elements.shouldEqual(set.elements)
            "\(deserialized.state.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 2]")
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

            let bytes = try system.serialization.serialize(message: set.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(CRDT.ORSet<String>.Delta.self, from: bytes)

            // delta contains the same elements as set
            "\(deserialized.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 2]")
            deserialized.versionContext.gaps.isEmpty.shouldBeTrue() // changes are contiguous so no gaps
            deserialized.elementByBirthDot.count.shouldEqual(2)
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right
        }
    }
}
