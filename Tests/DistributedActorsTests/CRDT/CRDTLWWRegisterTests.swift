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

final class CRDTLWWRegisterTests: XCTestCase {
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .perpetual))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .perpetual))

    func test_LWWRegister_assign_shouldSetValueAndTimestamp() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA)

        r1.value.shouldBeNil()
        r1.timestamp.shouldEqual(Date.distantPast)
        r1.updatedBy.shouldBeNil()

        r1.assign(3)

        r1.value.shouldEqual(3)
        r1.timestamp.shouldBeGreaterThan(Date.distantPast)
        r1.updatedBy.shouldEqual(self.replicaA)

        let oldTimestamp = r1.timestamp

        r1.assign(5)

        r1.value.shouldEqual(5)
        r1.timestamp.shouldBeGreaterThan(oldTimestamp)
        r1.updatedBy.shouldEqual(self.replicaA)
    }

    func test_LWWRegister_merge_shouldMutateIfMoreRecentTimestamp() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA)
        var r2 = CRDT.LWWRegister<Int>(replicaId: self.replicaB)

        r1.assign(3)
        // Make sure r2's assignment has a more recent timestamp
        r2.assign(5, timestamp: r1.timestamp.addingTimeInterval(1))

        // r1 is mutated; r2 is not
        r1.merge(other: r2)

        // r1 overwritten by r2's value
        r1.value.shouldEqual(5)
        r1.timestamp.shouldEqual(r2.timestamp)
        r1.updatedBy.shouldEqual(self.replicaB)

        r2.value.shouldEqual(5) // unchanged
    }

    func test_LWWRegister_merge_shouldNotMutateIfOlderTimestamp() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA)
        var r2 = CRDT.LWWRegister<Int>(replicaId: self.replicaB)

        r1.assign(3)
        // Make sure r2's assignment has an older timestamp
        r2.assign(5, timestamp: r1.timestamp.addingTimeInterval(-1))

        let r1OldTimestamp = r1.timestamp

        // r1 should not be mutated
        r1.merge(other: r2)

        r1.value.shouldEqual(3)
        r1.timestamp.shouldEqual(r1OldTimestamp)
        r1.updatedBy.shouldEqual(self.replicaA)
    }

    func test_LWWRegister_merging_shouldNotMutate() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA)
        var r2 = CRDT.LWWRegister<Int>(replicaId: self.replicaB)

        r1.assign(3)
        // Make sure r2's assignment has a more recent timestamp
        r2.assign(5, timestamp: r1.timestamp.addingTimeInterval(1))

        // Neither r1 nor r2 is mutated
        let r3 = r1.merging(other: r2)

        r1.value.shouldEqual(3) // unchanged
        r2.value.shouldEqual(5) // unchanged

        r3.value.shouldEqual(5)
        r3.timestamp.shouldEqual(r2.timestamp)
        r3.updatedBy.shouldEqual(self.replicaB)
    }

    func test_LWWRegister_reset() throws {
        var r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA)
        r1.assign(3)
        r1.value.shouldEqual(3)
        r1.timestamp.shouldBeGreaterThan(Date.distantPast)
        r1.updatedBy.shouldEqual(self.replicaA)

        r1.reset()

        r1.value.shouldBeNil()
        r1.timestamp.shouldEqual(Date.distantPast)
        r1.updatedBy.shouldBeNil()
    }
}
