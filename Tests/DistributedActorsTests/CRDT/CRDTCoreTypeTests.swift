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

final class CRDTCoreTypeTests: XCTestCase {
    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GCounter tests

    func test_GCounter_increment_shouldUpdateDelta() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))

        g1.increment(by: 1)
        // delta should not be nil after increment
        g1.delta.shouldNotBeNil()
        g1.delta!.state[g1.replicaId].shouldNotBeNil()
        g1.delta!.state[g1.replicaId]!.shouldEqual(1)

        g1.increment(by: 10)
        g1.delta.shouldNotBeNil()
        g1.delta!.state[g1.replicaId].shouldNotBeNil()
        // delta value for the replica should be updated
        g1.delta!.state[g1.replicaId]!.shouldEqual(11) // 1 + 10
    }

    func test_GCounter_merge_shouldMutate() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        // g1 is mutated; g2 is not
        g1.merge(other: g2)

        g1.value.shouldEqual(11) // 1 (g1) + 10 (g2)
        g1.delta.shouldBeNil() // delta is reset after merge
        g2.value.shouldEqual(10) // unchanged
        g2.delta.shouldNotBeNil()
    }

    func test_GCounter_merging_shouldNotMutate() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        // Neither g1 nor g2 is mutated
        let g3 = g1.merging(other: g2)

        g1.value.shouldEqual(1) // unchanged
        g1.delta.shouldNotBeNil() // delta should not be nil after increment
        g2.value.shouldEqual(10) // unchanged
        g2.delta.shouldNotBeNil() // delta should not be nil after increment
        g3.value.shouldEqual(11) // 1 (g1) + 10 (g2)
        g3.delta.shouldBeNil()
    }

    func test_GCounter_mergeDelta_shouldMutate() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        guard let d = g2.delta else {
            throw shouldNotHappen("g2.delta should not be nil after increment")
        }
        // g1 is mutated
        g1.mergeDelta(d)

        g1.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
        g1.delta.shouldBeNil() // delta is reset after mergeDelta
    }

    func test_GCounter_mergingDelta_shouldNotMutate() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        guard let d = g2.delta else {
            throw shouldNotHappen("g2.delta should not be nil after increment")
        }
        // g1 is not mutated
        let g3 = g1.mergingDelta(d)

        g1.value.shouldEqual(1) // unchanged
        g1.delta.shouldNotBeNil() // delta should not be nil after increment
        g3.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
        g3.delta.shouldBeNil()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ORSet tests

    func test_ORSet_basicOperations() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))

        s1.elements.isEmpty.shouldBeTrue()
        s1.count.shouldEqual(0)
        s1.isEmpty.shouldBeTrue()

        s1.add(1)
        s1.add(3)
        s1.remove(1)
        s1.add(5)

        s1.elements.shouldEqual([3, 5])
        s1.count.shouldEqual(2)
        s1.isEmpty.shouldBeFalse()

        s1.contains(3).shouldBeTrue()
        s1.contains(1).shouldBeFalse()

        s1.removeAll()

        s1.elements.isEmpty.shouldBeTrue()
        s1.count.shouldEqual(0)
        s1.isEmpty.shouldBeTrue()
    }

    func test_ORSet_add_remove_shouldUpdateDelta() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))

        // version 1
        s1.add(1)
        s1.elements.shouldEqual([1])
        s1.delta.shouldNotBeNil()
        s1.delta!.versionContext.vv[s1.replicaId].shouldEqual(1)
        s1.delta!.elementByBirthDot.count.shouldEqual(1)
        s1.delta!.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1)

        // version 2
        s1.add(3)
        s1.elements.shouldEqual([1, 3])
        s1.delta.shouldNotBeNil()
        s1.delta!.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.delta!.elementByBirthDot.count.shouldEqual(2) // two dots for different elements
        s1.delta!.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1)
        s1.delta!.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3)

        // `remove` doesn't increment version
        s1.remove(1)
        s1.elements.shouldEqual([3])
        s1.delta.shouldNotBeNil()
        s1.delta!.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.delta!.elementByBirthDot.count.shouldEqual(1)
        s1.delta!.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3)

        // version 3 - duplicate element, previous version(s) deleted
        s1.add(3)
        s1.elements.shouldEqual([3])
        s1.delta.shouldNotBeNil()
        s1.delta!.versionContext.vv[s1.replicaId].shouldEqual(3)
        // Any existing dots for the element are removed before inserting, which means there is a single dot per element
        s1.delta!.elementByBirthDot.count.shouldEqual(1)
        s1.delta!.elementByBirthDot[VersionDot(s1.replicaId, 3)]!.shouldEqual(3)
    }

    func test_ORSet_merge_shouldMutate() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))
        s1.add(1)
        s1.add(3)
        var s2 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerBeta))
        s2.add(3)
        s2.add(5)
        s2.add(1)

        // s1 is mutated
        s1.merge(other: s2)

        s1.elements.shouldEqual([1, 3, 5])
        s1.state.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaId].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(5)
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)]!.shouldEqual(3) // (B,1): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 2)]!.shouldEqual(5) // (B,2): 5
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 3)]!.shouldEqual(1) // (B,3): 1
        // (B,1): 3 and (B,3): 1 come from a different replica (B), so A cannot coalesce them.

        s1.delta.shouldBeNil() // delta reset after `merge`
    }

    func test_ORSet_merge_shouldMutate_shouldCompact() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))

        var s2 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerBeta))
        s2.add(7) // (B,1): 7

        s1.merge(other: s2) // Now s1 has (B,1): 7
        s1.contains(7).shouldBeTrue()
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)]!.shouldEqual(7) // (B,1): 7

        s1.add(1)
        s1.add(3)

        s2.add(3) // (B,2): 3
        s2.add(7) // (B,3): 7; (B,1) deleted with this add

        // s1 is mutated
        s1.merge(other: s2)

        s1.elements.shouldEqual([1, 3, 7])
        s1.state.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaId].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(4)
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)].shouldBeNil() // `compact` removes (B,1): 7
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 2)]!.shouldEqual(3) // (B,2): 3 in different replica than (A,2): 3, so not removed by `compact`
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 3)]!.shouldEqual(7) // (B,3): 7

        s1.delta.shouldBeNil() // delta reset after `merge`
    }

    func test_ORSet_mergeDelta_shouldMutate() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))
        s1.add(1)
        s1.add(3)
        var s2 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerBeta))
        s2.add(3)
        s2.add(5)
        s2.add(1)

        guard let d = s2.delta else {
            throw shouldNotHappen("s2.delta should not be nil after add")
        }
        // s1 is mutated
        s1.mergeDelta(d)

        s1.elements.shouldEqual([1, 3, 5])
        s1.state.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaId].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(5)
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)]!.shouldEqual(3) // (B,1): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 2)]!.shouldEqual(5) // (B,2): 5
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 3)]!.shouldEqual(1) // (B,3): 1
        // (B,1): 3 and (B,3): 1 come from a different replica (B), so A cannot coalesce them.

        s1.delta.shouldBeNil() // delta reset after `mergeDelta`
    }

    func test_ORSet_mergeDelta_shouldMutate_shouldCompact() throws {
        var s1 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerAlpha))

        var s2 = CRDT.ORSet<Int>(replicaId: .actorAddress(self.ownerBeta))
        s2.add(7) // (B,1): 7

        s1.merge(other: s2) // Now s1 has (B,1): 7
        s1.contains(7).shouldBeTrue()
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)]!.shouldEqual(7) // (B,1): 7

        s1.add(1)
        s1.add(3)

        s2.add(3) // (B,2): 3
        s2.add(7) // (B,3): 7; (B,1) deleted with this add

        guard let d = s2.delta else {
            throw shouldNotHappen("s2.delta should not be nil after add")
        }
        // s1 is mutated
        s1.mergeDelta(d)

        s1.elements.shouldEqual([1, 3, 7])
        s1.state.versionContext.vv[s1.replicaId].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaId].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(4)
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaId, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 1)].shouldBeNil() // `compact` removes (B,1): 7
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 2)]!.shouldEqual(3) // (B,2): 3 in different replica than (A,2): 3, so not removed by `compact`
        s1.state.elementByBirthDot[VersionDot(s2.replicaId, 3)]!.shouldEqual(7) // (B,3): 7

        s1.delta.shouldBeNil() // delta reset after `mergeDelta`
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: AnyCvRDT tests

    func test_AnyCvRDT_canBeUsedToMergeRightTypes() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        // Can have AnyCvRDT of different concrete CRDTs in same collection
        let anyCvRDTs: [CRDT.Identity: AnyCvRDT] = [
            "gcounter-1": AnyCvRDT(g1),
            "gcounter-2": AnyCvRDT(g2),
            "mock-1": AnyCvRDT(MockCvRDT()),
            "mock-2": AnyCvRDT(MockCvRDT()),
        ]

        guard var gg1: AnyCvRDT = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let gg2: AnyCvRDT = anyCvRDTs["gcounter-2"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        // g1 is mutated; g2 is not
        g1.merge(other: g2)

        g1.value.shouldEqual(11)
        g2.value.shouldEqual(10)

        // gg1 is mutated; gg2 is not
        gg1.merge(other: gg2)

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Underlying should be a GCounter")
        }
        guard let ugg2 = gg2.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Underlying should be a GCounter")
        }
        ugg1.value.shouldEqual(11)
        ugg2.value.shouldEqual(10)
    }

    func test_AnyCvRDT_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        let anyCvRDTs: [CRDT.Identity: AnyCvRDT] = [
            "gcounter-1": AnyCvRDT(g1),
            "mock-1": AnyCvRDT(MockCvRDT()),
        ]

        guard var gg1: AnyCvRDT = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let m1: AnyCvRDT = anyCvRDTs["mock-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        let error = shouldThrow {
            try gg1.tryMerge(other: m1)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleTypesMergeAttempted")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: AnyDeltaCRDT tests

    // AnyDeltaCRDT has at least the same features as AnyCvRDT
    func test_AnyDeltaCRDT_canBeUsedToMergeRightTypes() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        // A collection of AnyCvRDTs and AnyDeltaCRDTs
        let anyCRDTs: [CRDT.Identity: AnyStateBasedCRDT] = [
            "gcounter-1": g1.asAnyCvRDT,
            "gcounter-2": g2.asAnyCvRDT,
            "gcounter-as-delta-1": g1.asAnyDeltaCRDT,
            "gcounter-as-delta-2": g2.asAnyDeltaCRDT,
        ]

        guard var gg1 = anyCRDTs["gcounter-as-delta-1"] as? AnyDeltaCRDT else {
            throw shouldNotHappen("Should be a AnyDeltaCRDT")
        }
        guard let gg2 = anyCRDTs["gcounter-as-delta-2"] as? AnyDeltaCRDT else {
            throw shouldNotHappen("Should be a AnyDeltaCRDT")
        }

        // delta should not be nil since increment was called on underlying
        gg1.delta.shouldNotBeNil()
        gg2.delta.shouldNotBeNil()

        // gg1 is mutated; gg2 is not
        gg1.merge(other: gg2)

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        guard let ugg2 = gg2.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        ugg1.value.shouldEqual(11) // 1 (g1) + 10 (g2)
        ugg1.delta.shouldBeNil() // delta is reset after merge
        ugg2.value.shouldEqual(10) // unchanged
        ugg2.delta.shouldNotBeNil()
    }

    // AnyDeltaCRDT has at least the same features as AnyCvRDT
    func test_AnyDeltaCRDT_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        let anyDeltaCRDTs: [CRDT.Identity: AnyDeltaCRDT] = [
            "gcounter-1": g1.asAnyDeltaCRDT,
            "mock-1": AnyDeltaCRDT(MockDeltaCRDT()),
        ]

        guard var gg1: AnyDeltaCRDT = anyDeltaCRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let m1: AnyDeltaCRDT = anyDeltaCRDTs["mock-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        let error = shouldThrow {
            try gg1.tryMerge(other: m1)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleTypesMergeAttempted")
    }

    func test_AnyDeltaCRDT_canBeUsedToMergeRightDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g2.increment(by: 10)

        var gg1 = g1.asAnyDeltaCRDT
        let gg2 = g2.asAnyDeltaCRDT

        let d = gg2.delta! // ! safe because of nil check right above
        // gg1 is mutated
        gg1.mergeDelta(d)

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        ugg1.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
        ugg1.delta.shouldBeNil() // delta is reset after mergeDelta
    }

    func test_AnyDeltaCRDT_throwWhenAttemptToMergeInvalidDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        var gg1 = g1.asAnyDeltaCRDT
        let d = AnyCvRDT(MockCvRDT())

        let error = shouldThrow {
            try gg1.tryMergeDelta(d)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleDeltaTypeMergeAttempted")
    }

    func test_AnyDeltaCRDT_canResetDelta() throws {
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        var gg1 = g1.asAnyDeltaCRDT
        // gg1 is mutated
        gg1.resetDelta()

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        ugg1.delta.shouldBeNil()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT types for testing

// TODO: remove after we implement more CRDTs

struct MockCvRDT: CvRDT {
    mutating func merge(other: MockCvRDT) {
        print("MockCvRDT merge")
    }
}

struct MockDeltaCRDT: DeltaCRDT {
    typealias Delta = MockCvRDT

    var delta: Delta?

    mutating func merge(other: MockDeltaCRDT) {
        print("MockDeltaCRDT merge")
    }

    mutating func mergeDelta(_: Delta) {
        print("MockDeltaCRDT mergeDelta")
    }

    func resetDelta() {
        print("MockDeltaCRDT resetDelta")
    }
}
