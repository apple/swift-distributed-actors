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

final class CRDTORMapTests: XCTestCase {
    let replicaA: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORMap + GCounter tests

    func test_ORMap_GCounter_basicOperations() throws {
        var m1 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaA, defaultValue: CRDT.GCounter(replicaID: self.replicaA))

        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()

        m1.update(key: "g1") { $0.increment(by: 5) }
        m1.update(key: "g2") { $0.increment(by: 3) }
        m1.update(key: "g1") { $0.increment(by: 2) }

        guard let g1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        g1.value.shouldEqual(7) // 5 + 2

        guard let g2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        g2.value.shouldEqual(3)

        Set(m1.keys).shouldEqual(["g1", "g2"])
        m1.values.count.shouldEqual(2)
        m1.count.shouldEqual(2)
        m1.isEmpty.shouldBeFalse()

        // Delete g1
        _ = m1.unsafeRemoveValue(forKey: "g1")

        // g1 should no longer exist
        m1["g1"].shouldBeNil()

        // g2 - no change
        guard let gg2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        gg2.value.shouldEqual(3)

        Set(m1.keys).shouldEqual(["g2"])
        m1.values.count.shouldEqual(1)
        m1.count.shouldEqual(1)
        m1.isEmpty.shouldBeFalse()

        m1.unsafeRemoveAllValues()

        m1["g1"].shouldBeNil()
        m1["g2"].shouldBeNil()

        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()
    }

    func test_ORMap_GCounter_update_remove_shouldUpdateDelta() throws {
        var m1 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaA, defaultValue: CRDT.GCounter(replicaID: self.replicaA))

        m1.update(key: "g1") { $0.increment(by: 5) }
        m1.count.shouldEqual(1)

        guard let d1 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "g1"]
        // `values`: ["g1": GCounter(value = 5)]
        d1.keys.versionContext.vv[self.replicaA].shouldEqual(1)
        d1.keys.elementByBirthDot.count.shouldEqual(1)
        d1.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("g1")
        d1.values.count.shouldEqual(1)

        guard let dg1 = d1.values["g1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"g1\", got \(d1)")
        }
        dg1.value.shouldEqual(5)

        m1.update(key: "g2") { $0.increment(by: 3) }
        m1.count.shouldEqual(2)

        guard let d2 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "g1", (A,2): "g2"]
        // `values`: ["g1": GCounter(value = 5), "g2": GCounter(value = 3)]
        d2.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d2.keys.elementByBirthDot.count.shouldEqual(2) // two dots for different elements
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("g1")
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("g2")
        d2.values.count.shouldEqual(2)

        guard let dgg1 = d2.values["g1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"g1\", got \(d2)")
        }
        dgg1.value.shouldEqual(5)

        guard let dgg2 = d2.values["g2"] else {
            throw shouldNotHappen("Expect delta.values to contain \"g2\", got \(d2)")
        }
        dgg2.value.shouldEqual(3)

        _ = m1.unsafeRemoveValue(forKey: "g1")
        m1.count.shouldEqual(1) // g2

        guard let d3 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,2): "g2"]
        // `values`: ["g2": GCounter(value = 3)]
        // keys.elementByBirthDot does not contain g1 because it's been deleted, but keys.versionContext still has the version
        d3.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d3.keys.elementByBirthDot.count.shouldEqual(1)
        d3.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("g2")
        d3.values.count.shouldEqual(1)

        guard let dggg2 = d3.values["g2"] else {
            throw shouldNotHappen("Expect delta.values to contain \"g2\", got \(d3)")
        }
        dggg2.value.shouldEqual(3)

        m1.update(key: "g1") { $0.increment(by: 6) }
        m1.count.shouldEqual(2) // g1 and g2

        guard let d4 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,3): "g1", (A,2): "g2"]
        // `values`: ["g1": GCounter(value = 6), "g2": GCounter(value = 3)]
        d4.keys.versionContext.vv[self.replicaA].shouldEqual(3)
        d4.keys.elementByBirthDot.count.shouldEqual(2)
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 3)]!.shouldEqual("g1")
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("g2")
        d4.values.count.shouldEqual(2)

        guard let dggg1 = d4.values["g1"] else {
            throw shouldNotHappen("Expect delta.values to contain \"g1\", got \(d4)")
        }
        dggg1.value.shouldEqual(6)
    }

    func test_ORMap_GCounter_merge_shouldMutate() throws {
        var m1 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaA, defaultValue: CRDT.GCounter(replicaID: self.replicaA))

        var m2 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaB, defaultValue: CRDT.GCounter(replicaID: self.replicaB))
        // ORSet `keys`: [(B,1): "g1"]
        // `values`: ["g1": GCounter(value = 5)]
        m2.update(key: "g1") { // (B,1)
            $0.increment(by: 5)
        }

        m1.merge(other: m2)

        guard let g1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        g1.value.shouldEqual(5)

        m1._keys.elements.shouldEqual(["g1"])
        m1._keys.state.versionContext.vv[self.replicaA].shouldEqual(0)
        m1._keys.state.versionContext.vv[self.replicaB].shouldEqual(1)
        m1._keys.state.elementByBirthDot.count.shouldEqual(1)
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("g1")

        // ORSet `keys`: [(A,1): "g1", (A,2): "g2"]
        // `values`: ["g1": GCounter(value = 5 + 2 = 7), "g2": GCounter(value = 6)]
        m1.update(key: "g1") { // (A,1) replaces (B,1) because it's "newer"
            $0.increment(by: 2)
        }
        m1.update(key: "g2") { // (A,2)
            $0.increment(by: 6)
        }

        // ORSet `keys`: [(B,3): "g1", (B,2): "g2"]
        // `values`: ["g1": GCounter(value = 6), "g2": GCounter(value = 3)]
        m2.update(key: "g2") { // (B,2)
            $0.increment(by: 3)
        }
        m2.update(key: "g1") { // (B,3) replaces (B,1)
            $0.increment(by: 1)
        }

        // ORSet `keys`: [(A,1): "g1", (A,2): "g2", (B,2): "g2", (B,3): "g1"]
        // `values`: ["g1": GCounter(value = 2 (m1) + 6 (m2) = 8), "g2": GCounter(value = 6 (m1) + 3 (m2) = 9)]
        m1.merge(other: m2)

        guard let gg1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        gg1.value.shouldEqual(8)

        guard let gg2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        gg2.value.shouldEqual(9)

        m1._keys.elements.shouldEqual(["g1", "g2"])
        m1._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1._keys.state.versionContext.vv[self.replicaB].shouldEqual(3)
        m1._keys.state.elementByBirthDot.count.shouldEqual(4)
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("g1")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("g2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("g2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 3)]!.shouldEqual("g1")
    }

    func test_ORMap_GCounter_mergeDelta_shouldMutate() throws {
        var m1 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaA, defaultValue: CRDT.GCounter(replicaID: self.replicaA))
        // ORSet `keys`: [(A,1): "g1", (A,2): "g2"]
        // `values`: ["g1": GCounter(value = 8), "g2": GCounter(value = 6)]
        m1.update(key: "g1") { // (A,1)
            $0.increment(by: 8)
        }
        m1.update(key: "g2") { // (A,2)
            $0.increment(by: 6)
        }

        var m2 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaB, defaultValue: CRDT.GCounter(replicaID: self.replicaB))
        // ORSet `keys`: [(B,1): "g2", (B,2): "g3", (B,3): "g1"]
        // `values`: ["g1": GCounter(value = 2), "g2": GCounter(value = 3), "g3": GCounter(value = 5)]
        m2.update(key: "g2") { // (B,1)
            $0.increment(by: 3)
        }
        m2.update(key: "g3") { // (B,2)
            $0.increment(by: 5)
        }
        m2.update(key: "g1") { // (B,3)
            $0.increment(by: 2)
        }

        guard let delta = m2.delta else {
            throw shouldNotHappen("m2.delta should not be nil after updates")
        }
        // ORSet `keys`: [(A,1): "g1", (A,2): "g2", (B,1): "g2", (B,2): "g3", (B,3): "g1"]
        // `values`: ["g1": GCounter(value = 8 (m1) + 2 (m2) = 10), "g2": GCounter(value = 6 (m1) + 3 (m2) = 9), "g3": GCounter(value = 5)]
        m1.mergeDelta(delta)

        guard let g1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        g1.value.shouldEqual(10)

        guard let g2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        g2.value.shouldEqual(9)

        guard let g3 = m1["g3"] else {
            throw shouldNotHappen("Expect m1 to contain \"g3\", got \(m1)")
        }
        g3.value.shouldEqual(5)

        m1._keys.elements.shouldEqual(["g1", "g2", "g3"])
        m1._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1._keys.state.versionContext.vv[self.replicaB].shouldEqual(3)
        m1._keys.state.elementByBirthDot.count.shouldEqual(5)
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("g1")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("g2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("g2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("g3")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 3)]!.shouldEqual("g1")
    }

    func test_ORMap_GCounter_resetValue_resetAllValues() throws {
        var m1 = CRDT.ORMap<String, CRDT.GCounter>(replicaID: self.replicaA, defaultValue: CRDT.GCounter(replicaID: self.replicaA))
        m1.update(key: "g1") {
            $0.increment(by: 2)
        }
        m1.update(key: "g2") {
            $0.increment(by: 6)
        }

        guard let g1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        g1.value.shouldEqual(2)

        guard let g2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        g2.value.shouldEqual(6)

        m1.resetValue(forKey: "g1")

        guard let gg1 = m1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1)")
        }
        gg1.value.shouldEqual(0) // reset

        guard let gg2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        gg2.value.shouldEqual(6) // no change

        m1.resetAllValues()

        guard let ggg2 = m1["g2"] else {
            throw shouldNotHappen("Expect m1 to contain \"g2\", got \(m1)")
        }
        ggg2.value.shouldEqual(0)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORMap + ORSet tests

    func test_ORMap_ORSet_basicOperations() throws {
        var m1 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaA, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaA))

        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()

        m1.update(key: "s1") { $0.insert(1) }
        m1.update(key: "s2") { $0.insert(3) }
        m1.update(key: "s1") { $0.insert(5) }

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        s1.elements.shouldEqual([1, 5])

        guard let s2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        s2.elements.shouldEqual([3])

        Set(m1.keys).shouldEqual(["s1", "s2"])
        m1.values.count.shouldEqual(2)
        m1.count.shouldEqual(2)
        m1.isEmpty.shouldBeFalse()

        // Delete s1
        _ = m1.unsafeRemoveValue(forKey: "s1")

        // s1 should no longer exist
        m1["s1"].shouldBeNil()

        // s2 - no change
        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.elements.shouldEqual([3])

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

    func test_ORMap_ORSet_removeValue_shouldRemoveInOtherReplicas() throws {
        var m1 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaA, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaA))
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m1.update(key: "s1") { // (A,1)
            $0.insert(1)
            $0.insert(5)
        }
        m1.update(key: "s2") { // (A,2)
            $0.insert(3)
        }

        var m2 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaB, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaB))

        guard let delta1 = m1.delta else {
            throw shouldNotHappen("m1.delta should not be nil after updates")
        }
        // m2 is in-sync with m1
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m2.mergeDelta(delta1)

        guard let s1 = m2["s1"] else {
            throw shouldNotHappen("Expect m2 to contain \"s1\", got \(m2)")
        }
        s1.elements.shouldEqual([1, 5])

        guard let s2 = m2["s2"] else {
            throw shouldNotHappen("Expect m2 to contain \"s2\", got \(m2)")
        }
        s2.elements.shouldEqual([3])

        // Delete s1 from m1 (WARNING: this causes us to lose causal history for s1!!!)
        // ORSet `keys`: [(A,2): "s2"]
        // `values`: ["s2": [3]]
        _ = m1.unsafeRemoveValue(forKey: "s1")

        guard let delta2 = m1.delta else {
            throw shouldNotHappen("m1.delta should not be nil after updates")
        }
        // Replicate the changes to m2
        // ORSet `keys`: [(A,2): "s2"]
        // `values`: ["s2": [3]]
        m2.mergeDelta(delta2)

        // s1 should be deleted from m2 as well
        m2["s1"].shouldBeNil()

        // s2 - no change
        guard let ss2 = m2["s2"] else {
            throw shouldNotHappen("Expect m2 to contain \"s2\", got \(m2)")
        }
        ss2.elements.shouldEqual([3])

        m2._keys.elements.shouldEqual(["s2"])
        m2._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m2._keys.state.versionContext.vv[self.replicaB].shouldEqual(0)
        m2._keys.state.elementByBirthDot.count.shouldEqual(1)
        m2._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
    }

    /// Demonstrates how using `unsafeRemoveValue` may potentially revive deleted elements (i.e., element in the deleted
    /// ORSet) when replication has not been propagated yet and there are concurrent updates, because of the loss of
    /// causal history associated with `unsafeRemoveValue`.
    func test_ORMap_ORSet_removeValue_revivesDeletedElementsOnMerge() throws {
        var m1 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaA, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaA))
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m1.update(key: "s1") { // (A,1)
            $0.insert(1)
            $0.insert(5)
        }
        m1.update(key: "s2") { // (A,2)
            $0.insert(3)
        }

        var m2 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaB, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaB))

        guard let delta = m1.delta else {
            throw shouldNotHappen("m1.delta should not be nil after updates")
        }
        // m2 is in-sync with m1
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m2.mergeDelta(delta)

        guard let s1 = m2["s1"] else {
            throw shouldNotHappen("Expect m2 to contain \"s1\", got \(m2)")
        }
        s1.elements.shouldEqual([1, 5])

        guard let s2 = m2["s2"] else {
            throw shouldNotHappen("Expect m2 to contain \"s2\", got \(m2)")
        }
        s2.elements.shouldEqual([3])

        // Delete s1 from m1 (WARNING: this causes us to lose causal history for s1!!!)
        // ORSet `keys`: [(A,2): "s2"]
        // `values`: ["s2": [3]]
        _ = m1.unsafeRemoveValue(forKey: "s1")

        // m2 doesn't know about deletion of m1.s1

        // (Concurrent) update s1 in m2
        // ORSet `keys`: [(B,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5, 7], "s2": [3]]
        m2.update(key: "s1") { // (B,1) replaces (A,1) because it's "newer"
            $0.insert(5) // re-add
            $0.insert(7) // new
        }

        // This will bring m2.s1 to m1 and since m1 doesn't have causal history of s1 it re-adds the deleted
        // elements (e.g., 1).
        // ORSet `keys`: [(B,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5, 7], "s2": [3]]
        m1.merge(other: m2)

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        ss1.elements.shouldEqual([1, 5, 7])

        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.elements.shouldEqual([3])

        m1._keys.elements.shouldEqual(["s1", "s2"])
        m1._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1._keys.state.versionContext.vv[self.replicaB].shouldEqual(1)
        m1._keys.state.elementByBirthDot.count.shouldEqual(2)
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("s1")
    }

    /// Demonstrates that as long as the value CRDT is kept around (e.g., delete elements in an ORSet by using
    /// `update` and `ORSet.removeAll` vs. delete ORSet's key from ORMap then create another ORSet instance), the
    /// causal history is retained and deleted elements will not come back even though changes might not have been
    /// replicated yet.
    func test_ORMap_ORSet_update_deletedElementsShouldNotReviveOnMerge() throws {
        var m1 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaA, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaA))
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m1.update(key: "s1") { // (A,1)
            $0.insert(1)
            $0.insert(5)
        }
        m1.update(key: "s2") { // (A,2)
            $0.insert(3)
        }

        var m2 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaB, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaB))

        guard let delta = m1.delta else {
            throw shouldNotHappen("m1.delta should not be nil after updates")
        }
        // m2 is in-sync with m1
        // ORSet `keys`: [(A,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5], "s2": [3]]
        m2.mergeDelta(delta)

        guard let s1 = m2["s1"] else {
            throw shouldNotHappen("Expect m2 to contain \"s1\", got \(m2)")
        }
        s1.elements.shouldEqual([1, 5])

        guard let s2 = m2["s2"] else {
            throw shouldNotHappen("Expect m2 to contain \"s2\", got \(m2)")
        }
        s2.elements.shouldEqual([3])

        // Use `update` to clear s1 in m1 to keep causal history
        // ORSet `keys`: [(A,3): "s1", (A,2): "s2"]
        // `values`: ["s1": [], "s2": [3]]
        m1.update(key: "s1") { // (A,3)
            $0.removeAll()
        }

        // m2 doesn't know about the changes made in m1.s1

        // Update s1 in m2
        // ORSet `keys`: [(B,1): "s1", (A,2): "s2"]
        // `values`: ["s1": [1, 5, 7], "s2": [3]]
        m2.update(key: "s1") { // (B,1) replaces (A,1) because it's "newer"
            $0.insert(5) // re-add
            $0.insert(7) // new
        }

        // This will bring m2.s1 to m1 but deleted m1.s1 elements (i.e., 1, 5) should not be revived because
        // causal history is retained. m1.s1 knows that the element 1 has been deleted, so even though m2.s1 has it
        // it doesn't get added back to m1.s1.
        // The merged m1.s1 has 5 because m2.s1 has added it independently.
        // ORSet `keys`: [(A,3): "s1", (A,2): "s2", (B,1): "s1"]
        // `values`: ["s1": [5, 7], "s2": [3]]
        m1.merge(other: m2)

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        ss1.elements.shouldEqual([5, 7])

        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.elements.shouldEqual([3])

        m1._keys.elements.shouldEqual(["s1", "s2"])
        m1._keys.state.versionContext.vv[self.replicaA].shouldEqual(3)
        m1._keys.state.versionContext.vv[self.replicaB].shouldEqual(1)
        m1._keys.state.elementByBirthDot.count.shouldEqual(3)
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("s2")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaA, 3)]!.shouldEqual("s1")
        m1._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("s1")
    }

    func test_ORMap_ORSet_resetValue_resetAllValues() throws {
        var m1 = CRDT.ORMap<String, CRDT.ORSet<Int>>(replicaID: self.replicaA, defaultValue: CRDT.ORSet<Int>(replicaID: self.replicaA))
        m1.update(key: "s1") { $0.insert(1) }
        m1.update(key: "s2") { $0.insert(3) }
        m1.update(key: "s1") { $0.insert(5) }

        guard let s1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        s1.elements.shouldEqual([1, 5])

        guard let s2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        s2.elements.shouldEqual([3])

        m1.resetValue(forKey: "s1")

        guard let ss1 = m1["s1"] else {
            throw shouldNotHappen("Expect m1 to contain \"s1\", got \(m1)")
        }
        ss1.isEmpty.shouldBeTrue() // reset

        guard let ss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        ss2.elements.shouldEqual([3]) // no change

        m1.resetAllValues()

        guard let sss2 = m1["s2"] else {
            throw shouldNotHappen("Expect m1 to contain \"s2\", got \(m1)")
        }
        sss2.isEmpty.shouldBeTrue()
    }
}
