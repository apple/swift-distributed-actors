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

final class CRDTGCounterTests: XCTestCase {
    var node: UniqueNode { .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random()) }
    lazy var replicaA: ReplicaID = .actorAddress(try! ActorAddress(local: node, path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    lazy var replicaB: ReplicaID = .actorAddress(try! ActorAddress(local: node, path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    func test_increment_shouldUpdateDelta() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)

        g1.increment(by: 1)
        // delta should not be nil after increment
        g1.delta.shouldNotBeNil()
        g1.delta!.state[g1.replicaID].shouldNotBeNil()
        g1.delta!.state[g1.replicaID]!.shouldEqual(1)

        g1.increment(by: 10)
        g1.delta.shouldNotBeNil()
        g1.delta!.state[g1.replicaID].shouldNotBeNil()
        // delta value for the replica should be updated
        g1.delta!.state[g1.replicaID]!.shouldEqual(11) // 1 + 10
    }

    func test_merge_shouldMutate() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaID: self.replicaB)
        g2.increment(by: 10)

        // g1 is mutated; g2 is not
        g1.merge(other: g2)

        g1.value.shouldEqual(11) // 1 (g1) + 10 (g2)
        g2.value.shouldEqual(10) // unchanged
    }

    func test_increment_byZero_shouldBeNoop() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        g1.increment(by: 0)
        g1.increment(by: 10)

        g1.value.shouldEqual(11) // 1 (g1) + 10 (g2)
    }

    func test_merging_shouldNotMutate() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaID: self.replicaB)
        g2.increment(by: 10)

        // Neither g1 nor g2 is mutated
        let g3 = g1.merging(other: g2)

        g1.value.shouldEqual(1) // unchanged
        g1.delta.shouldNotBeNil() // delta should not be nil after increment
        g2.value.shouldEqual(10) // unchanged
        g2.delta.shouldNotBeNil() // delta should not be nil after increment
        g3.value.shouldEqual(11) // 1 (g1) + 10 (g2)
    }

    func test_mergeDelta_shouldMutate() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaID: self.replicaB)
        g2.increment(by: 10)

        guard let d = g2.delta else {
            throw shouldNotHappen("g2.delta should not be nil after increment")
        }
        // g1 is mutated
        g1.mergeDelta(d)

        g1.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
    }

    func test_mergingDelta_shouldNotMutate() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        var g2 = CRDT.GCounter(replicaID: self.replicaB)
        g2.increment(by: 10)

        guard let d = g2.delta else {
            throw shouldNotHappen("g2.delta should not be nil after increment")
        }
        // g1 is not mutated
        let g3 = g1.mergingDelta(d)

        g1.value.shouldEqual(1) // unchanged
        g1.delta.shouldNotBeNil() // delta should not be nil after increment
        g3.value.shouldEqual(11) // 1 (g1) + 10 (g2 delta)
    }

    func test_reset() throws {
        var g1 = CRDT.GCounter(replicaID: self.replicaA)
        g1.increment(by: 1)
        g1.increment(by: 5)
        g1.value.shouldEqual(6)

        g1.reset()
        g1.value.shouldEqual(0)
    }
}
