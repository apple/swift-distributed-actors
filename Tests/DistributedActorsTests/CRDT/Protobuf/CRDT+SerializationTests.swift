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
import Foundation
import XCTest

final class CRDTSerializationTests: ActorSystemTestBase {
    typealias V = UInt64

    override func setUp() {
        _ = self.setUpNode(String(describing: type(of: self))) { settings in
            // TODO: all this registering will go away with _mangledTypeName
            settings.serialization.register(CRDT.ORSet<String>.self, serializerID: Serialization.ReservedID.CRDTORSet)
            settings.serialization.register(CRDT.ORSet<String>.Delta.self, serializerID: Serialization.ReservedID.CRDTORSetDelta)
            settings.serialization.register(CRDT.LWWRegister<Int>.self, serializerID: Serialization.ReservedID.CRDTLWWRegister)
        }
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .wellKnown)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Identity

    func test_serializationOf_Identity() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("test-crdt")

            let serialized = try system.serialization.serialize(id)
            let deserialized = try system.serialization.deserialize(as: CRDT.Identity.self, from: serialized)

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

            let serialized = try system.serialization.serialize(versionContext)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionContext.self, from: serialized)

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

            let serialized = try system.serialization.serialize(versionContext)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionContext.self, from: serialized)

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
            var versionedContainer = CRDT.VersionedContainer(replicaID: replicaAlpha, versionContext: versionContext, elementByBirthDot: elementByBirthDot)
            // Adding an element should set delta
            versionedContainer.add("bye")

            let serialized = try system.serialization.serialize(versionedContainer)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionedContainer<String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
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
            let versionedContainer = CRDT.VersionedContainer<String>(replicaID: .actorAddress(ownerAlpha))

            let serialized = try system.serialization.serialize(versionedContainer)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionedContainer<String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
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
            var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)

            let serialized = try system.serialization.serialize(g1)
            let deserialized = try system.serialization.deserialize(as: CRDT.GCounter.self, from: serialized)

            g1.value.shouldEqual(deserialized.value)
            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 2]")
        }
    }

    func test_serializationOf_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
            g1.increment(by: 13)

            let serialized = try system.serialization.serialize(g1.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(as: CRDT.GCounter.Delta.self, from: serialized)

            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 13]")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORSet

    func test_serializationOf_ORSet() throws {
        try shouldNotThrow {
            var set: CRDT.ORSet<String> = CRDT.ORSet(replicaID: .actorAddress(self.ownerAlpha))
            set.add("hello") // (alpha, 1)
            set.add("world") // (alpha, 2)
            set.remove("nein")
            set.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(set)
            let deserialized = try system.serialization.deserialize(as: CRDT.ORSet<String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
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
            var set: CRDT.ORSet<String> = CRDT.ORSet(replicaID: .actorAddress(self.ownerAlpha))
            set.add("hello") // (alpha, 1)
            set.add("world") // (alpha, 2)
            set.remove("nein")

            let serialized = try system.serialization.serialize(set.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(as: CRDT.ORSet<String>.Delta.self, from: serialized)

            // delta contains the same elements as set
            "\(deserialized.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:9001/user/alpha: 2]")
            deserialized.versionContext.gaps.isEmpty.shouldBeTrue() // changes are contiguous so no gaps
            deserialized.elementByBirthDot.count.shouldEqual(2)
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LWWRegister

    func test_serializationOf_LWWRegister() throws {
        try shouldNotThrow {
            let clock = WallTime()
            var register: CRDT.LWWRegister<Int> = CRDT.LWWRegister(replicaID: .actorAddress(self.ownerAlpha), initialValue: 6, clock: .wallTime(clock))
            register.assign(8)

            let serialized = try system.serialization.serialize(register)
            let deserialized = try system.serialization.deserialize(as: CRDT.LWWRegister<Int>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            deserialized.initialValue.shouldEqual(6)
            deserialized.timeSource.shouldEqual(.wallTime)
            deserialized.value.shouldEqual(8)
            "\(deserialized.updatedBy)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")

            guard case .wallTime(let deserializedClock) = deserialized.clock else {
                throw self.testKit.fail("Expected clock to be .wallTime, got \(deserialized.clock)")
            }
//            print("\(fabs(deserializedClock.timestamp.timeIntervalSince1970 - clock.timestamp.timeIntervalSince1970))")
//            (fabs(deserializedClock.timestamp.timeIntervalSince1970 - clock.timestamp.timeIntervalSince1970) < Double.ulpOfOne).shouldBeTrue()
            XCTAssertEqual(deserializedClock.timestamp.timeIntervalSince1970, clock.timestamp.timeIntervalSince1970, accuracy: 1)

            // The way `Date`/`Codable` handles fractional seconds makes it difficult
            // to compare `Date` before and after serialization. We settle with comparing
            // ISO-8601 representation of `Date`.
//            if #available(macOS 10.13, *) {
//                Formatter.iso8601WithFractionalSeconds.string(from: deserialized.clock.timestamp)
//                    .shouldEqual(Formatter.iso8601WithFractionalSeconds.string(from: clock.timestamp))
//            }
        }
    }
}
