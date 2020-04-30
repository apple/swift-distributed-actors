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

final class CRDTLWWRegisterTests: XCTestCase {
    let replicaA: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    func test_assign_shouldSetValueAndTimestamp() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaID: self.replicaA, initialValue: 3)
        r1.value.shouldEqual(3)
        r1.updatedBy.shouldEqual(self.replicaA)
        r1.initialValue.shouldEqual(3)

        let oldClock = r1.clock

        r1.assign(5)

        r1.value.shouldEqual(5)
        r1.clock.shouldBeGreaterThan(oldClock)
        r1.updatedBy.shouldEqual(self.replicaA)
        r1.initialValue.shouldEqual(3) // doesn't change
    }

    func test_merge_shouldMutateIfMoreRecentTimestamp() throws {
        let r1Clock = WallTimeClock()
        var r1 = CRDT.LWWRegister<Int>(replicaID: self.replicaA, initialValue: 3, clock: r1Clock)
        // Make sure r2's assignment has a more recent timestamp
        let r2 = CRDT.LWWRegister<Int>(replicaID: self.replicaB, initialValue: 5, clock: WallTimeClock(timestamp: r1Clock.timestamp.addingTimeInterval(1)))

        // r1 is mutated; r2 is not
        r1.merge(other: r2)

        // r1 overwritten by r2's value
        r1.value.shouldEqual(5)
        r1.clock.shouldEqual(r2.clock)
        r1.updatedBy.shouldEqual(self.replicaB)
        r1.initialValue.shouldEqual(3) // doesn't change

        r2.value.shouldEqual(5) // unchanged
    }

    func test_merge_shouldNotMutateIfOlderTimestamp() throws {
        let r1Clock = WallTimeClock()
        var r1 = CRDT.LWWRegister<Int>(replicaID: self.replicaA, initialValue: 3, clock: r1Clock)
        // Make sure r2's assignment has an older timestamp
        let r2 = CRDT.LWWRegister<Int>(replicaID: self.replicaB, initialValue: 5, clock: WallTimeClock(timestamp: r1Clock.timestamp.addingTimeInterval(-1)))

        let r1OldClock = r1.clock

        // r1 should not be mutated
        r1.merge(other: r2)

        r1.value.shouldEqual(3)
        r1.clock.shouldEqual(r1OldClock)
        r1.updatedBy.shouldEqual(self.replicaA)
    }

    func test_merging_shouldNotMutate() throws {
        let r1Clock = WallTimeClock()
        let r1 = CRDT.LWWRegister<Int>(replicaID: self.replicaA, initialValue: 3, clock: r1Clock)
        // Make sure r2's assignment has a more recent timestamp
        let r2 = CRDT.LWWRegister<Int>(replicaID: self.replicaB, initialValue: 5, clock: WallTimeClock(timestamp: r1Clock.timestamp.addingTimeInterval(1)))

        // Neither r1 nor r2 is mutated
        let r3 = r1.merging(other: r2)

        r1.value.shouldEqual(3) // unchanged
        r2.value.shouldEqual(5) // unchanged

        r3.value.shouldEqual(5)
        r3.clock.shouldEqual(r2.clock)
        r3.updatedBy.shouldEqual(self.replicaB)
        r3.initialValue.shouldEqual(r1.initialValue) // r3 is built from r1
    }

    func test_reset() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaID: self.replicaA, initialValue: 3)
        r1.initialValue.shouldEqual(3)

        // Make sure r1's value is changed to something different
        r1.assign(5)
        r1.value.shouldEqual(5)

        r1.reset()

        // `reset` changes `value` to `initialValue`
        r1.value.shouldEqual(3)
    }

    func test_optionalValueType() throws {
        var r1 = CRDT.LWWRegister<Int?>(replicaID: self.replicaA)
        r1.initialValue.shouldBeNil()
        r1.value.shouldBeNil()
        r1.updatedBy.shouldEqual(self.replicaA)

        r1.assign(3)

        r1.value.shouldEqual(3)
    }
}
