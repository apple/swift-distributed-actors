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

final class CRDTORSetTests: XCTestCase {
    let replicaA: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    func test_basicOperations() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)

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

    func test_add_remove_shouldUpdateDelta() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)

        // version 1
        s1.add(1)
        s1.elements.shouldEqual([1])
        guard let d1 = s1.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(s1)")
        }
        d1.versionContext.vv[s1.replicaID].shouldEqual(1)
        d1.elementByBirthDot.count.shouldEqual(1)
        d1.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1)

        // version 2
        s1.add(3)
        s1.elements.shouldEqual([1, 3])
        guard let d2 = s1.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(s1)")
        }
        d2.versionContext.vv[s1.replicaID].shouldEqual(2)
        d2.elementByBirthDot.count.shouldEqual(2) // two dots for different elements
        d2.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1)
        d2.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3)

        // `remove` doesn't increment version
        s1.remove(1)
        s1.elements.shouldEqual([3])
        guard let d3 = s1.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(s1)")
        }
        d3.versionContext.vv[s1.replicaID].shouldEqual(2)
        d3.elementByBirthDot.count.shouldEqual(1)
        d3.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3)

        // version 3 - duplicate element, previous version(s) deleted
        s1.add(3)
        s1.elements.shouldEqual([3])
        guard let d4 = s1.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(s1)")
        }
        d4.versionContext.vv[s1.replicaID].shouldEqual(3)
        // Any existing dots for the element are removed before inserting, which means there is a single dot per element
        d4.elementByBirthDot.count.shouldEqual(1)
        d4.elementByBirthDot[VersionDot(s1.replicaID, 3)]!.shouldEqual(3)
    }

    func test_merge_shouldMutate() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)
        s1.add(1)
        s1.add(3)
        var s2 = CRDT.ORSet<Int>(replicaID: self.replicaB)
        s2.add(3)
        s2.add(5)
        s2.add(1)

        // s1 is mutated
        s1.merge(other: s2)

        s1.elements.shouldEqual([1, 3, 5])
        s1.state.versionContext.vv[s1.replicaID].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaID].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(5)
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)]!.shouldEqual(3) // (B,1): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 2)]!.shouldEqual(5) // (B,2): 5
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 3)]!.shouldEqual(1) // (B,3): 1
        // (B,1): 3 and (B,3): 1 come from a different replica (B), so A cannot coalesce them.
    }

    func test_merge_shouldMutate_shouldCompact() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)

        var s2 = CRDT.ORSet<Int>(replicaID: self.replicaB)
        s2.add(7) // (B,1): 7

        s1.merge(other: s2) // Now s1 has (B,1): 7
        s1.contains(7).shouldBeTrue()
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)]!.shouldEqual(7) // (B,1): 7

        s1.add(1)
        s1.add(3)

        s2.add(3) // (B,2): 3
        s2.add(7) // (B,3): 7; (B,1) deleted with this add

        // s1 is mutated
        s1.merge(other: s2)

        s1.elements.shouldEqual([1, 3, 7])
        s1.state.versionContext.vv[s1.replicaID].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaID].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(4)
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)].shouldBeNil() // `compact` removes (B,1): 7
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 2)]!.shouldEqual(3) // (B,2): 3 in different replica than (A,2): 3, so not removed by `compact`
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 3)]!.shouldEqual(7) // (B,3): 7
    }

    func test_mergeDelta_shouldMutate() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)
        s1.add(1)
        s1.add(3)
        var s2 = CRDT.ORSet<Int>(replicaID: self.replicaB)
        s2.add(3)
        s2.add(5)
        s2.add(1)

        guard let d = s2.delta else {
            throw shouldNotHappen("s2.delta should not be nil after add")
        }
        // s1 is mutated
        s1.mergeDelta(d)

        s1.elements.shouldEqual([1, 3, 5])
        s1.state.versionContext.vv[s1.replicaID].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaID].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(5)
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)]!.shouldEqual(3) // (B,1): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 2)]!.shouldEqual(5) // (B,2): 5
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 3)]!.shouldEqual(1) // (B,3): 1
        // (B,1): 3 and (B,3): 1 come from a different replica (B), so A cannot coalesce them.
    }

    func test_mergeDelta_shouldMutate_shouldCompact() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)

        var s2 = CRDT.ORSet<Int>(replicaID: self.replicaB)
        s2.add(7) // (B,1): 7

        s1.merge(other: s2) // Now s1 has (B,1): 7
        s1.contains(7).shouldBeTrue()
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)]!.shouldEqual(7) // (B,1): 7

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
        s1.state.versionContext.vv[s1.replicaID].shouldEqual(2)
        s1.state.versionContext.vv[s2.replicaID].shouldEqual(3)
        s1.state.elementByBirthDot.count.shouldEqual(4)
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 1)]!.shouldEqual(1) // (A,1): 1
        s1.state.elementByBirthDot[VersionDot(s1.replicaID, 2)]!.shouldEqual(3) // (A,2): 3
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 1)].shouldBeNil() // `compact` removes (B,1): 7
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 2)]!.shouldEqual(3) // (B,2): 3 in different replica than (A,2): 3, so not removed by `compact`
        s1.state.elementByBirthDot[VersionDot(s2.replicaID, 3)]!.shouldEqual(7) // (B,3): 7
    }

    func test_reset() throws {
        var s1 = CRDT.ORSet<Int>(replicaID: self.replicaA)
        s1.add(1)
        s1.add(3)
        s1.elements.shouldEqual([1, 3])

        s1.reset()
        s1.isEmpty.shouldBeTrue()
    }

    func test_clone() throws {
        var s = CRDT.ORSet<Int>(replicaID: self.replicaA)
        s.add(3)

        let clone = s.clone()
        clone.replicaID.shouldEqual(s.replicaID)
        clone.elements.shouldEqual(s.elements)
        clone.delta.shouldNotBeNil()
    }
}
