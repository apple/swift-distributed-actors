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
        let anyCvRDTs: [CRDT.Identity: AnyCvRDT] = [
            "gcounter-1": AnyCvRDT(g1),
            "gcounter-2": AnyCvRDT(g2),
            "lwwreg-1": AnyCvRDT(r1),
            "lwwreg-2": AnyCvRDT(r2),
        ]

        guard var gg1: AnyCvRDT = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let gg2: AnyCvRDT = anyCvRDTs["gcounter-2"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

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

        guard var rr1: AnyCvRDT = anyCvRDTs["lwwreg-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let rr2: AnyCvRDT = anyCvRDTs["lwwreg-2"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        // rr1 is mutated; rr2 is not
        rr1.merge(other: rr2)

        guard let urr1 = rr1.underlying as? CRDT.LWWRegister<Int> else {
            throw shouldNotHappen("Underlying should be a LWWRegister<Int>")
        }
        guard let urr2 = rr2.underlying as? CRDT.LWWRegister<Int> else {
            throw shouldNotHappen("Underlying should be a LWWRegister<Int>")
        }
        urr1.value.shouldEqual(5)
        urr2.value.shouldEqual(5)
    }

    func test_AnyCvRDT_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        let r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3)

        let anyCvRDTs: [CRDT.Identity: AnyCvRDT] = [
            "gcounter-1": AnyCvRDT(g1),
            "lwwreg-1": AnyCvRDT(r1),
        ]

        guard var gg1: AnyCvRDT = anyCvRDTs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let rr1: AnyCvRDT = anyCvRDTs["lwwreg-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        let error = shouldThrow {
            try gg1.tryMerge(other: rr1)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleTypesMergeAttempted")
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
        let anyCRDTs: [CRDT.Identity: AnyStateBasedCRDT] = [
            "gcounter-1": g1.asAnyCvRDT,
            "gcounter-2": g2.asAnyCvRDT,
            "gcounter-as-delta-1": g1.asDeltaCRDTBox,
            "gcounter-as-delta-2": g2.asDeltaCRDTBox,
        ]

        guard var gg1 = anyCRDTs["gcounter-as-delta-1"] as? DeltaCRDTBox else {
            throw shouldNotHappen("Should be a DeltaCRDTBox")
        }
        guard let gg2 = anyCRDTs["gcounter-as-delta-2"] as? DeltaCRDTBox else {
            throw shouldNotHappen("Should be a DeltaCRDTBox")
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
        ugg2.value.shouldEqual(10) // unchanged
    }

    // DeltaCRDTBox has at least the same features as AnyCvRDT
    func test_DeltaCRDTBox_throwWhenIncompatibleTypesAttemptToBeMerged() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var s1 = CRDT.ORSet<Int>(replicaId: self.replicaA)
        s1.add(3)

        let DeltaCRDTBoxs: [CRDT.Identity: DeltaCRDTBox] = [
            "gcounter-1": g1.asDeltaCRDTBox,
            "orset-1": s1.asDeltaCRDTBox,
        ]

        guard var gg1: DeltaCRDTBox = DeltaCRDTBoxs["gcounter-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }
        guard let ss1: DeltaCRDTBox = DeltaCRDTBoxs["orset-1"] else {
            throw shouldNotHappen("Dictionary should not return nil for key")
        }

        let error = shouldThrow {
            try gg1.tryMerge(other: ss1)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleTypesMergeAttempted")
    }

    func test_DeltaCRDTBox_canBeUsedToMergeRightDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaId: self.replicaB)
        g2.increment(by: 10)

        var gg1 = g1.asDeltaCRDTBox
        let gg2 = g2.asDeltaCRDTBox

        let d = gg2.delta! // ! safe because of nil check right above
        // gg1 is mutated
        gg1.mergeDelta(d)

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        ugg1.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
    }

    func test_DeltaCRDTBox_throwWhenAttemptToMergeInvalidDeltaType() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var s1 = CRDT.ORSet<Int>(replicaId: self.replicaA)
        s1.add(3)

        var gg1 = g1.asDeltaCRDTBox

        guard let d = s1.delta else {
            throw shouldNotHappen("Delta should not be nil")
        }

        let error = shouldThrow {
            try gg1.tryMergeDelta(d.asAnyCvRDT)
        }
        "\(error)".shouldStartWith(prefix: "incompatibleDeltaTypeMergeAttempted")
    }

    func test_DeltaCRDTBox_canResetDelta() throws {
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        var gg1 = g1.asDeltaCRDTBox
        // gg1 should have delta
        gg1.delta.shouldNotBeNil()
        gg1.resetDelta()

        guard let ugg1 = gg1.underlying as? CRDT.GCounter else {
            throw shouldNotHappen("Should be a GCounter")
        }
        ugg1.delta.shouldBeNil()
    }
}
