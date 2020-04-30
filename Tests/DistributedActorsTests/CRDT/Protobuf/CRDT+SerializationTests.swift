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
            settings.serialization.register(CRDT.ORMap<String, CRDT.ORSet<String>>.self, serializerID: Serialization.ReservedID.CRDTORMap)
            settings.serialization.register(CRDT.ORMap<String, CRDT.ORSet<String>>.Delta.self, serializerID: Serialization.ReservedID.CRDTORMapDelta)
            settings.serialization.register(CRDT.ORMultiMap<String, String>.self, serializerID: Serialization.ReservedID.CRDTORMultiMap)
            settings.serialization.register(CRDT.ORMultiMap<String, String>.Delta.self, serializerID: Serialization.ReservedID.CRDTORMultiMapDelta)
            settings.serialization.register(CRDT.LWWMap<String, String>.self, serializerID: Serialization.ReservedID.CRDTLWWMap)
            settings.serialization.register(CRDT.LWWMap<String, String>.Delta.self, serializerID: Serialization.ReservedID.CRDTLWWMapDelta)
            settings.serialization.register(CRDT.LWWRegister<Int>.self, serializerID: Serialization.ReservedID.CRDTLWWRegister)
            settings.serialization.register(CRDT.LWWRegister<String>.self, serializerID: Serialization.ReservedID.CRDTLWWRegister)
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
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 1")
            "\(deserialized.vv)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/beta: 3")

            deserialized.gaps.count.shouldEqual(1)
            "\(deserialized.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha,4)")
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

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 3") // adding "bye" bumps version to 3
            "\(deserialized.versionContext.vv)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/beta: 1")
            "\(deserialized.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/beta,3)")
            deserialized.elementByBirthDot.count.shouldEqual(3)
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/beta,3): \"world\"")
            "\(deserialized.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha,3): \"bye\"")

            deserialized.delta.shouldNotBeNil()
            // The birth dot for "bye" is added to gaps since delta's versionContext started out empty
            // and therefore not contiguous
            deserialized.delta!.versionContext.vv.isEmpty.shouldBeTrue()
            "\(deserialized.delta!.versionContext.gaps)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha,3)")
            deserialized.delta!.elementByBirthDot.count.shouldEqual(1)
            "\(deserialized.delta!.elementByBirthDot)".shouldContain("Dot(actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha,3): \"bye\"")
        }
    }

    func test_serializationOf_VersionedContainer_empty() throws {
        try shouldNotThrow {
            let versionedContainer = CRDT.VersionedContainer<String>(replicaID: .actorAddress(ownerAlpha))

            let serialized = try system.serialization.serialize(versionedContainer)
            let deserialized = try system.serialization.deserialize(as: CRDT.VersionedContainer<String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
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
            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 2]")
        }
    }

    func test_serializationOf_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
            g1.increment(by: 13)

            let serialized = try system.serialization.serialize(g1.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(as: CRDT.GCounter.Delta.self, from: serialized)

            "\(deserialized.state)".shouldContain("[actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 13]")
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

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
            deserialized.elements.shouldEqual(set.elements)
            "\(deserialized.state.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 2]")
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
            "\(deserialized.versionContext.vv)".shouldContain("[actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha: 2]")
            deserialized.versionContext.gaps.isEmpty.shouldBeTrue() // changes are contiguous so no gaps
            deserialized.elementByBirthDot.count.shouldEqual(2)
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized.elementByBirthDot)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORMap

    func test_serializationOf_ORMap() throws {
        try shouldNotThrow {
            var map = CRDT.ORMap<String, CRDT.ORSet<String>>(replicaID: .actorAddress(self.ownerAlpha), defaultValue: CRDT.ORSet<String>(replicaID: .actorAddress(self.ownerAlpha)))
            map.update(key: "s1") { $0.add("a") }
            map.update(key: "s2") { $0.add("b") }
            map.update(key: "s1") { $0.add("c") }
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map)
            let deserialized = try system.serialization.deserialize(as: CRDT.ORMap<String, CRDT.ORSet<String>>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
            deserialized.defaultValue.shouldBeNil()
            deserialized._keys.elements.shouldEqual(["s1", "s2"])
            deserialized._values.count.shouldEqual(2)

            guard let s1 = deserialized["s1"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s1\", got \(deserialized)")
            }
            s1.elements.shouldEqual(["a", "c"])

            guard let s2 = deserialized["s2"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s2\", got \(deserialized)")
            }
            s2.elements.shouldEqual(["b"])

            // Contains same element as `values`
            deserialized.updatedValues.count.shouldEqual(2)

            // Derived from `updatedValues`
            deserialized.delta.shouldNotBeNil()
            deserialized.delta!.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count) // same elements added to delta
            deserialized.delta!.values.count.shouldEqual(2)
        }
    }

    func test_serializationOf_ORMap_delta() throws {
        try shouldNotThrow {
            var map = CRDT.ORMap<String, CRDT.ORSet<String>>(replicaID: .actorAddress(self.ownerAlpha), defaultValue: CRDT.ORSet<String>(replicaID: .actorAddress(self.ownerAlpha)))
            map.update(key: "s1") { $0.add("a") }
            map.update(key: "s2") { $0.add("b") }
            map.update(key: "s1") { $0.add("c") }
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map.delta!) // !-safe, must have a delta, we just checked it
            let deserialized = try system.serialization.deserialize(as: CRDT.ORMap<String, CRDT.ORSet<String>>.Delta.self, from: serialized)

            deserialized.defaultValue.shouldBeNil()
            deserialized.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count)
            deserialized.values.count.shouldEqual(2)

            // delta contains the same elements as map
            guard let s1 = deserialized.values["s1"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s1\", got \(deserialized)")
            }
            s1.elements.shouldEqual(["a", "c"])

            guard let s2 = deserialized.values["s2"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s2\", got \(deserialized)")
            }
            s2.elements.shouldEqual(["b"])
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORMultiMap

    func test_serializationOf_ORMultiMap() throws {
        try shouldNotThrow {
            var map = CRDT.ORMultiMap<String, String>(replicaID: .actorAddress(self.ownerAlpha))
            map.add(forKey: "s1", "a")
            map.add(forKey: "s2", "b")
            map.add(forKey: "s1", "c")
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map)
            let deserialized = try system.serialization.deserialize(as: CRDT.ORMultiMap<String, String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            deserialized.state._keys.elements.shouldEqual(["s1", "s2"])
            deserialized.state._values.count.shouldEqual(2)

            guard let s1 = deserialized["s1"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s1\", got \(deserialized)")
            }
            s1.shouldEqual(["a", "c"])

            guard let s2 = deserialized["s2"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s2\", got \(deserialized)")
            }
            s2.shouldEqual(["b"])

            deserialized.delta.shouldNotBeNil()
            deserialized.delta!.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count) // same elements added to delta
            deserialized.delta!.values.count.shouldEqual(2)
        }
    }

    func test_serializationOf_ORMultiMap_delta() throws {
        try shouldNotThrow {
            var map = CRDT.ORMultiMap<String, String>(replicaID: .actorAddress(self.ownerAlpha))
            map.add(forKey: "s1", "a")
            map.add(forKey: "s2", "b")
            map.add(forKey: "s1", "c")
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map.delta!) // !-safe, must have a delta, we just checked it
            let deserialized = try system.serialization.deserialize(as: CRDT.ORMultiMap<String, String>.Delta.self, from: serialized)

            // Delta is just `ORMapDelta`
            deserialized.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count)
            deserialized.values.count.shouldEqual(2)

            // delta contains the same elements as map
            guard let s1 = deserialized.values["s1"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s1\", got \(deserialized)")
            }
            s1.elements.shouldEqual(["a", "c"])

            guard let s2 = deserialized.values["s2"] else {
                throw shouldNotHappen("Expect deserialized to contain \"s2\", got \(deserialized)")
            }
            s2.elements.shouldEqual(["b"])
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LWWMap

    func test_serializationOf_LWWMap() throws {
        try shouldNotThrow {
            var map = CRDT.LWWMap<String, String>(replicaID: .actorAddress(self.ownerAlpha), defaultValue: "")
            map.set(forKey: "foo", value: "a")
            map.set(forKey: "bar", value: "b")
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map)
            let deserialized = try system.serialization.deserialize(as: CRDT.LWWMap<String, String>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@localhost:9001/user/alpha")
            deserialized.state._keys.elements.shouldEqual(["foo", "bar"])
            deserialized.state._values.count.shouldEqual(2)

            guard let foo = deserialized["foo"] else {
                throw shouldNotHappen("Expect deserialized to contain \"foo\", got \(deserialized)")
            }
            foo.shouldEqual("a")

            guard let bar = deserialized["bar"] else {
                throw shouldNotHappen("Expect deserialized to contain \"bar\", got \(deserialized)")
            }
            bar.shouldEqual("b")

            deserialized.delta.shouldNotBeNil()
            deserialized.delta!.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count) // same elements added to delta
            deserialized.delta!.values.count.shouldEqual(2)
        }
    }

    func test_serializationOf_LWWMap_delta() throws {
        try shouldNotThrow {
            var map = CRDT.LWWMap<String, String>(replicaID: .actorAddress(self.ownerAlpha), defaultValue: "")
            map.set(forKey: "foo", value: "a")
            map.set(forKey: "bar", value: "b")
            map.delta.shouldNotBeNil()

            let serialized = try system.serialization.serialize(map.delta!) // !-safe, must have a delta, we just checked it
            let deserialized = try system.serialization.deserialize(as: CRDT.LWWMap<String, String>.Delta.self, from: serialized)

            // Delta is just `ORMapDelta`
            deserialized.keys.elementByBirthDot.count.shouldEqual(map.delta!.keys.elementByBirthDot.count)
            deserialized.values.count.shouldEqual(2)

            // delta contains the same elements as map
            guard let foo = deserialized.values["foo"] else {
                throw shouldNotHappen("Expect deserialized to contain \"foo\", got \(deserialized)")
            }
            foo.value.shouldEqual("a")

            guard let bar = deserialized.values["bar"] else {
                throw shouldNotHappen("Expect deserialized to contain \"bar\", got \(deserialized)")
            }
            bar.value.shouldEqual("b")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LWWRegister

    func test_serializationOf_LWWRegister() throws {
        try shouldNotThrow {
            let clock = WallTimeClock()
            var register: CRDT.LWWRegister<Int> = CRDT.LWWRegister(replicaID: .actorAddress(self.ownerAlpha), initialValue: 6, clock: clock)
            register.assign(8)

            let serialized = try system.serialization.serialize(register)
            let deserialized = try system.serialization.deserialize(as: CRDT.LWWRegister<Int>.self, from: serialized)

            "\(deserialized.replicaID)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")
            deserialized.initialValue.shouldEqual(6)
            deserialized.value.shouldEqual(8)
            "\(deserialized.updatedBy)".shouldContain("actor:sact://CRDTSerializationTests@127.0.0.1:9001/user/alpha")

            // `TimeInterval` is `Double`
            XCTAssertEqual(deserialized.clock.timestamp.timeIntervalSince1970, clock.timestamp.timeIntervalSince1970, accuracy: 1)
        }
    }
}
