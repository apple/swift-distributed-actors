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
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .perpetual))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .perpetual))

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
        ugg2.value.shouldEqual(10) // unchanged
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
        // gg1 should have delta
        gg1.delta.shouldNotBeNil()
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
