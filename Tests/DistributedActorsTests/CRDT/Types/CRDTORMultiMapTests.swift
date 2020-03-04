//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
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

final class CRDTORMultiMapTests: XCTestCase {
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    func test_ORMultiMap_basicOperations() throws {
        var m1 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaA)

        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()

        m1.add(forKey: "s1", 9)
        m1.add(forKey: "s2", 0)
        m1.add(forKey: "s1", 6)

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expected m1 to contain \"s1\", got \(m1)")
        }
        s1.shouldEqual([9, 6])

        guard let s2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        s2.shouldEqual([0])

        Set(m1.keys).shouldEqual(["s1", "s2"])
        m1.values.count.shouldEqual(2)
        m1.count.shouldEqual(2)
        m1.isEmpty.shouldBeFalse()

        // Remove 9 from s1
        m1.remove(forKey: "s1", 9)

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expected m1 to contain \"s1\", got \(m1)")
        }
        ss1.shouldEqual([6])

        // Delete s1
        _ = m1.unsafeRemoveValue(forKey: "s1")

        // s1 should no longer exist
        m1["s1"].shouldBeNil()

        // s2 - no change
        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.shouldEqual([0])

        Set(m1.keys).shouldEqual(["s2"])
        m1.values.count.shouldEqual(1)
        m1.count.shouldEqual(1)
        m1.isEmpty.shouldBeFalse()

        m1.unsafeRemoveAllValues()

        m1["s1"].shouldBeNil()
        m1["s2"].shouldBeNil()

        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()
    }

    func test_ORMultiMap_GCounter_add_remove_shouldUpdateDelta() throws {
        var m1 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaA)

        m1.add(forKey: "s1", 9)
        m1.count.shouldEqual(1)

        guard let d1 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "s1"]
        // `values`: ["s1": [9]]
        d1.keys.versionContext.vv[self.replicaA].shouldEqual(1)
        d1.keys.elementByBirthDot.count.shouldEqual(1)
        d1.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("s1")
        d1.values.count.shouldEqual(1)

        guard let ds1 = d1.values["s1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"s1\", got \(d1)")
        }
        ds1.elements.shouldEqual([9])

        m1.add(forKey: "s2", 7)
        m1.count.shouldEqual(2)

        guard let d2 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [9], "s2": [7]]
        d2.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d2.keys.elementByBirthDot.count.shouldEqual(2) // two dots for different elements
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("s1")
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        d2.values.count.shouldEqual(2)

        guard let dss1 = d2.values["s1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"s1\", got \(d2)")
        }
        dss1.elements.shouldEqual([9])

        guard let dss2 = d2.values["s2"] else {
            throw shouldNotHappen("Expect delta.values to contain \"s2\", got \(d2)")
        }
        dss2.elements.shouldEqual([7])

        _ = m1.unsafeRemoveValue(forKey: "s1")
        m1.count.shouldEqual(1) // s2

        guard let d3 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,2): "s2"]
        // `values`: ["s2": [7]]
        // keys.elementByBirthDot does not contain s1 because it's been deleted, but keys.versionContext still has the version
        d3.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d3.keys.elementByBirthDot.count.shouldEqual(1)
        d3.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        d3.values.count.shouldEqual(1)

        guard let dsss2 = d3.values["s2"] else {
            throw shouldNotHappen("Expect delta.values to contain \"s2\", got \(d3)")
        }
        dsss2.elements.shouldEqual([7])

        m1.add(forKey: "s1", 16)
        m1.count.shouldEqual(2) // s1 and s2

        guard let d4 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,3): "s1", (A,2): "s2"]
        // `values`: ["s1": [16], "s2": [7]]
        d4.keys.versionContext.vv[self.replicaA].shouldEqual(3)
        d4.keys.elementByBirthDot.count.shouldEqual(2)
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 3)]!.shouldEqual("s1")
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        d4.values.count.shouldEqual(2)

        guard let dsss1 = d4.values["s1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"s1\", got \(d4)")
        }
        dsss1.elements.shouldEqual([16])
    }

    func test_ORMultiMap_merge_shouldMutate() throws {
        var m1 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaA)
        var m2 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaB)

        // ORSet `keys`: [(B,1): "s1"]
        // `values`: ["s1": [5]]
        m2.add(forKey: "s1", 5) // (B,1)

        m1.merge(other: m2)

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        s1.shouldEqual([5])

        m1.state._keys.elements.shouldEqual(["s1"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(0)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(1)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(1)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("s1")

        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [5, 2], "s2": [6]]
        m1.add(forKey: "s1", 2) // (A,1) replaces (B,1) because it's "newer"
        m1.add(forKey: "s2", 6) // (A,2)

        // ORSet `keys`: [(B,3): "s1", (B,2): "s2"]
        // `values`: ["s1": [5, 1], "s2": [3]]
        m2.add(forKey: "s2", 3) // (B,2)
        m2.add(forKey: "s1", 1) // (B,3) replaces (B,1)

        // ORSet `keys`: [(A,1): "s1", (A,2): "s2", (B,2): "s2", (B,3): "s1"]
        // `values`: ["s1": [2 (m1), 1 (m2), 5 (m1 & m2)], "s2": [6 (m1), 3 (m2)]]
        m1.merge(other: m2)

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        ss1.shouldEqual([2, 1, 5])

        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.shouldEqual([6, 3])

        m1.state._keys.elements.shouldEqual(["s1", "s2"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(3)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(4)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("s1")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("s2")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 3)]!.shouldEqual("s1")
    }

    func test_ORMultiMap_mergeDelta_shouldMutate() throws {
        var m1 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaA)
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [8], "s2": [6]]
        m1.add(forKey: "s1", 8) // (A,1)
        m1.add(forKey: "s2", 6) // (A,2)

        var m2 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaB)
        // ORSet `keys`: [(B,1): "s2", (B,2): "s3", (B,3): "s1"]
        // `values`: ["s1": [2], "s2": [3], "s3": [5]]
        m2.add(forKey: "s2", 3) // (B,1)
        m2.add(forKey: "s3", 5) // (B,2)
        m2.add(forKey: "s1", 2) // (B,3)

        guard let delta = m2.delta else {
            throw shouldNotHappen("m2.delta should not be nil after updates")
        }
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2", (B,1): "s2", (B,2): "s3", (B,3): "s1"]
        // `values`: ["s1": [8 (m1), 2 (m2)], "s2": [6 (m1), 3 (m2)], "s3": [5]]
        m1.mergeDelta(delta)

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        s1.shouldEqual([8, 2])

        guard let s2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        s2.shouldEqual([6, 3])

        guard let s3 = m1["s3"] else {
            throw shouldNotHappen("Expect m1 to contain \"s3\", got \(m1)")
        }
        s3.shouldEqual([5])

        m1.state._keys.elements.shouldEqual(["s1", "s2", "s3"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(3)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(5)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("s1")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("s2")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("s3")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 3)]!.shouldEqual("s1")
    }

    func test_ORMultiMap_removeAll() throws {
        var m1 = CRDT.ORMultiMap<String, Int>(replicaId: self.replicaA)
        m1.add(forKey: "s1", 2)
        m1.add(forKey: "s2", 6)

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        s1.shouldEqual([2])

        guard let s2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        s2.shouldEqual([6])

        m1.removeAll(forKey: "s1")

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        ss1.isEmpty.shouldBeTrue()

        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.shouldEqual([6]) // no change
    }
}
