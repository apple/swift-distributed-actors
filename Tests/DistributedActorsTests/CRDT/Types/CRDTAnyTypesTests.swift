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

final class CRDTAnyTypesTests: XCTestCase {
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: AnyCvRDT tests

    func test_AnyCvRDT_canBeUsedToMergeRightTypes() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: self.replicaB)
        g2.increment(by: 10)

        let r1Clock = WallTimeClock()
        let r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3, clock: .wallTime(r1Clock))
        // Make sure r2's assignment has a more recent timestamp
        let r2 = CRDT.LWWRegister<Int>(replicaId: self.replicaB, initialValue: 5, clock: .wallTime(WallTimeClock(timestamp: r1Clock.timestamp.addingTimeInterval(1))))

        // Can have AnyCvRDT of different concrete CRDTs in same collection
        let anyCvRDTs: [CRDT.Identity: StateBasedCRDT] = [
            "gcounter-1": g1,
            #"gcounter-2"#: g2,
            "lwwreg-1": r1,
            "lwwreg-2": r2,
        ]

        guard var gg1 = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let gg2 = anyCvRDTs["gcounter-2"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        // gg1 is mutated; gg2 is not
        let error = gg1._tryMerge(other: gg2)
        error.shouldBeNil()

        guard let ugg1 = gg1 as? CRDT.GCounter else {
            throw shouldNotHappen("Underlying should be a GCounter")
        }
        guard let ugg2 = gg2 as? CRDT.GCounter else {
            throw shouldNotHappen("Underlying should be a GCounter")
        }
        ugg1.value.shouldEqual(11)
        ugg2.value.shouldEqual(10)

        guard var rr1 = anyCvRDTs["lwwreg-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let rr2 = anyCvRDTs["lwwreg-2"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        // rr1 is mutated; rr2 is not
        let error2 = rr1._tryMerge(other: rr2)
        error2.shouldBeNil()

        guard let urr1 = rr1 as? CRDT.LWWRegister<Int> else {
            throw shouldNotHappen("Underlying should be a LWWRegister<Int>")
        }
        guard let urr2 = rr2 as? CRDT.LWWRegister<Int> else {
            throw shouldNotHappen("Underlying should be a LWWRegister<Int>")
        }
        urr1.value.shouldEqual(5)
        urr2.value.shouldEqual(5)
    }

    func test_AnyCvRDT_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        let r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3)

        let anyCvRDTs: [CRDT.Identity: StateBasedCRDT] = [
            "gcounter-1": g1,
            "lwwreg-1": r1,
        ]

        guard var gg1 = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let rr1 = anyCvRDTs["lwwreg-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        if gg1._tryMerge(other: rr1) != nil {
            () // good error was expected
        } else {
            throw TestError("Expected an error to be returned!")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: DeltaCRDTBox tests

    // DeltaCRDTBox has at least the same features as AnyCvRDT
    func test_DeltaCRDTBox_canBeUsedToMergeRightTypes() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: self.replicaB)
        g2.increment(by: 10)

        // A collection of AnyCvRDTs and DeltaCRDTBoxs
        let anyCRDTs: [CRDT.Identity: StateBasedCRDT] = [
            "gcounter-1": g1,
            "gcounter-2": g2,
            "gcounter-as-delta-1": g1,
            "gcounter-as-delta-2": g2,
        ]

        guard var gg1 = anyCRDTs["gcounter-as-delta-1"] as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a value")
        }
        guard let gg2 = anyCRDTs["gcounter-as-delta-2"] as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a value")
        }

        // delta should not be nil since increment was called on underlying
        gg1.delta.shouldNotBeNil()
        gg2.delta.shouldNotBeNil()

        // gg1 is mutated; gg2 is not
        gg1.merge(other: gg2)

        gg1.value.shouldEqual(11) // 1 (g1) + 10 (g2)
        gg2.value.shouldEqual(10) // unchanged
    }

    // DeltaCRDTBox has at least the same features as AnyCvRDT
    func test_DeltaCRDTBox_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var s1 = CRDT.ORSet<Int>(replicaId: self.replicaA)
        s1.add(3)

        let anyCvRDTs: [CRDT.Identity: StateBasedCRDT] = [
            "gcounter-1": g1,
            "orset-1": s1,
        ]

        guard var gg1 = anyCvRDTs["gcounter-1"] as? CRDT.GCounter else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        let error: CRDT.MergeError? = gg1._tryMerge(other: s1)
        error.shouldNotBeNil()
    }

    func test_DeltaCRDTBox_canBeUsedToMergeRightDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: self.replicaB)
        g2.increment(by: 10)

        var gg1 = g1
        let gg2 = g2

        let d = gg2.delta! // ! safe because of nil check right above
        // gg1 is mutated
        gg1.mergeDelta(d)

        gg1.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
    }

    func test_DeltaCRDTBox_throwWhenAttemptToMergeInvalidDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var s1 = CRDT.ORSet<Int>(replicaId: self.replicaA)
        s1.add(3)

        var gg1 = g1

        guard let d = s1.delta else {
            throw shouldNotHappen("Delta should not be nil")
        }

        let error = gg1._tryMerge(other: d)
        error.shouldNotBeNil()
    }

    func test_DeltaCRDTBox_canResetDelta() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var gg1 = g1
        // gg1 should have delta
        gg1.delta.shouldNotBeNil()
        gg1.resetDelta()

        gg1.delta.shouldBeNil()
    }
}
