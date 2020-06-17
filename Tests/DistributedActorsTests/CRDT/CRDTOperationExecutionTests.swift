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

final class CRDTOperationExecutionTests: ClusteredActorSystemsXCTestCase {
    var localSystem: ActorSystem!
    var localTestKit: ActorTestKit!

    var remoteSystem: ActorSystem!
    var remoteTestKit: ActorTestKit!

    func setUpLocal() {
        self.localSystem = super.setUpNode("local")
        self.localTestKit = super.testKit(self.localSystem)
    }

    func setUpRemote() {
        self.remoteSystem = super.setUpNode("remote")
        self.remoteTestKit = super.testKit(self.remoteSystem)
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .wellKnown)

    let timeout = TimeAmount.seconds(1)

    typealias OwnerMessage = CRDT.Replication.DataOwnerMessage
    typealias Message = CRDT.Replicator.Message
    typealias LocalRegisterResult = CRDT.Replicator.LocalCommand.RegisterResult
    typealias LocalWriteResult = CRDT.Replicator.LocalCommand.WriteResult
    typealias LocalReadResult = CRDT.Replicator.LocalCommand.ReadResult
    typealias LocalDeleteResult = CRDT.Replicator.LocalCommand.DeleteResult
    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    typealias RemoteReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    typealias RemoteDeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult
    typealias OperationExecution = CRDT.Replicator.OperationExecution

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: OperationExecution

    func test_OperationExecution_consistency_local() throws {
        let remoteMembersCount = 5

        let localConfirmed = try OperationExecution<Int>(with: .local, remoteMembersCount: remoteMembersCount, localConfirmed: true)
        localConfirmed.localConfirmed.shouldBeTrue()
        localConfirmed.confirmationsRequired.shouldEqual(1)
        localConfirmed.remoteConfirmationsNeeded.shouldEqual(0)
        localConfirmed.fulfilled.shouldBeTrue()
        localConfirmed.remoteFailuresAllowed.shouldEqual(0)
        localConfirmed.failed.shouldBeFalse()
    }

    func test_OperationExecution_consistency_local_throwIfLocalNotConfirmed() throws {
        let remoteMembersCount = 5

        let error = shouldThrow {
            _ = try OperationExecution<Int>(with: .local, remoteMembersCount: remoteMembersCount, localConfirmed: false)
        }

        guard case CRDT.OperationConsistency.Error.unableToFulfill(_, let localConfirmed, let required, let remaining, let obtainable) = error else {
            throw self.localTestKit.fail("Expected .unableToFulfill with required: 1, remaining: 1, obtainable: 0, got \(error)")
        }
        localConfirmed.shouldBeFalse()
        required.shouldEqual(1)
        remaining.shouldEqual(1)
        obtainable.shouldEqual(0)
    }

    func test_OperationExecution_consistency_atLeast() throws {
        self.setUpLocal()

        let remoteMembersCount = 5
        let replicatorP = self.localTestKit.spawnTestProbe(expecting: Message.self)

        var localConfirmed = try OperationExecution<Int>(with: .atLeast(2), remoteMembersCount: remoteMembersCount, localConfirmed: true)
        localConfirmed.localConfirmed.shouldBeTrue()
        localConfirmed.confirmationsRequired.shouldEqual(2)
        localConfirmed.remoteConfirmationsNeeded.shouldEqual(1) // 2 - 1 (local)
        localConfirmed.fulfilled.shouldBeFalse()
        localConfirmed.remoteConfirmationsReceived.count.shouldEqual(0)
        localConfirmed.remoteFailuresAllowed.shouldEqual(4) // 5 - 1 (needed)
        localConfirmed.remoteFailuresCount.shouldEqual(0)
        localConfirmed.failed.shouldBeFalse()

        // One confirmation is all it needs
        localConfirmed.confirm(from: replicatorP.ref, result: 1)
        localConfirmed.fulfilled.shouldBeTrue()
        localConfirmed.remoteConfirmationsReceived.count.shouldEqual(1)
        localConfirmed.remoteFailuresCount.shouldEqual(0)

        let localNotConfirmed = try OperationExecution<Int>(with: .atLeast(2), remoteMembersCount: remoteMembersCount, localConfirmed: false)
        localNotConfirmed.localConfirmed.shouldBeFalse()
        localNotConfirmed.confirmationsRequired.shouldEqual(2)
        localNotConfirmed.remoteConfirmationsNeeded.shouldEqual(2)
        localNotConfirmed.fulfilled.shouldBeFalse()
        localNotConfirmed.remoteFailuresAllowed.shouldEqual(3) // 5 - 2 (needed)

        let remoteNotNeeded = try OperationExecution<Int>(with: .atLeast(1), remoteMembersCount: remoteMembersCount, localConfirmed: true)
        remoteNotNeeded.confirmationsRequired.shouldEqual(1)
        remoteNotNeeded.remoteConfirmationsNeeded.shouldEqual(0)
        remoteNotNeeded.fulfilled.shouldBeTrue() // need only 1 and local already confirmed
    }

    func test_OperationExecution_consistency_atLeast_failedShouldBeTrueIfExceedAllowedRemoteFailures() throws {
        self.setUpLocal()

        let remoteMembersCount = 5
        let replicatorP = self.localTestKit.spawnTestProbe(expecting: Message.self)

        var localNotConfirmed = try OperationExecution<Int>(with: .atLeast(5), remoteMembersCount: remoteMembersCount, localConfirmed: false)
        localNotConfirmed.localConfirmed.shouldBeFalse()
        localNotConfirmed.confirmationsRequired.shouldEqual(5)
        localNotConfirmed.remoteConfirmationsNeeded.shouldEqual(5)
        localNotConfirmed.fulfilled.shouldBeFalse()
        localNotConfirmed.remoteConfirmationsReceived.count.shouldEqual(0)
        localNotConfirmed.remoteFailuresAllowed.shouldEqual(0) // 5 - 5 (needed)
        localNotConfirmed.remoteFailuresCount.shouldEqual(0)
        localNotConfirmed.failed.shouldBeFalse()

        // It only takes one remote failure to fail the operation
        localNotConfirmed.failed(at: replicatorP.ref)
        localNotConfirmed.fulfilled.shouldBeFalse()
        localNotConfirmed.remoteFailuresCount.shouldEqual(1)
        localNotConfirmed.failed.shouldBeTrue()
    }

    func test_OperationExecution_consistency_atLeast_throwIfInvalidInput() throws {
        let remoteMembersCount = 5

        let error = shouldThrow {
            _ = try OperationExecution<Int>(with: .atLeast(0), remoteMembersCount: remoteMembersCount, localConfirmed: true)
        }

        guard case CRDT.OperationConsistency.Error.invalidNumberOfReplicasRequested = error else {
            throw self.localTestKit.fail("Expected .invalidNumberOfReplicasRequested, got \(error)")
        }
    }

    func test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localConfirmed() throws {
        let remoteMembersCount = 5

        let error = shouldThrow {
            // Ask for 1 more than remote + local combined
            _ = try OperationExecution<Int>(with: .atLeast(remoteMembersCount + 2), remoteMembersCount: remoteMembersCount, localConfirmed: true)
        }

        guard case CRDT.OperationConsistency.Error.unableToFulfill(_, let localConfirmed, let required, let remaining, let obtainable) = error else {
            throw self.localTestKit.fail("Expected .unableToFulfill with required: \(remoteMembersCount + 2), remaining: \(remoteMembersCount + 1), obtainable: \(remoteMembersCount), got \(error)")
        }
        localConfirmed.shouldBeTrue()
        required.shouldEqual(remoteMembersCount + 2) // what we ask for
        remaining.shouldEqual(remoteMembersCount + 1) // 1 less because localConfirmed = true
        obtainable.shouldEqual(remoteMembersCount)
    }

    func test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localNotConfirmed() throws {
        let remoteMembersCount = 5

        let error = shouldThrow {
            // `remoteMembersCount + 1` essentially means we want all members to confirm.
            // Send false for `localConfirmed` so the operation cannot be fulfilled.
            _ = try OperationExecution<Int>(with: .atLeast(remoteMembersCount + 1), remoteMembersCount: remoteMembersCount, localConfirmed: false)
        }

        guard case CRDT.OperationConsistency.Error.unableToFulfill(_, let localConfirmed, let required, let remaining, let obtainable) = error else {
            throw self.localTestKit.fail("Expected .unableToFulfill with required: \(remoteMembersCount + 1), remaining: \(remoteMembersCount + 1), obtainable: \(remoteMembersCount), got \(error)")
        }
        localConfirmed.shouldBeFalse()
        required.shouldEqual(remoteMembersCount + 1) // what we ask for
        remaining.shouldEqual(remoteMembersCount + 1) // because localConfirmed is false
        obtainable.shouldEqual(remoteMembersCount)
    }

    func test_OperationExecution_consistency_quorum() throws {
        self.setUpLocal()

        let remoteMembersCount = 5
        let replicatorP = self.localTestKit.spawnTestProbe(expecting: Message.self)

        var localConfirmed = try OperationExecution<Int>(with: .quorum, remoteMembersCount: remoteMembersCount, localConfirmed: true)
        localConfirmed.localConfirmed.shouldBeTrue()
        localConfirmed.confirmationsRequired.shouldEqual(4) // quorum = (5 + 1) / 2 + 1 = 4
        localConfirmed.remoteConfirmationsNeeded.shouldEqual(3) // needed = 4 - 1 (local)
        localConfirmed.fulfilled.shouldBeFalse()
        localConfirmed.remoteFailuresAllowed.shouldEqual(2) // 5 - 3 (needed)
        localConfirmed.failed.shouldBeFalse()

        localConfirmed.confirm(from: replicatorP.ref, result: 1)
        localConfirmed.fulfilled.shouldBeFalse() // need 2 confirmations, only got 1
        localConfirmed.remoteConfirmationsReceived.count.shouldEqual(1)
        localConfirmed.remoteFailuresCount.shouldEqual(0)

        let localNotConfirmed = try OperationExecution<Int>(with: .quorum, remoteMembersCount: remoteMembersCount, localConfirmed: false)
        localNotConfirmed.localConfirmed.shouldBeFalse()
        localNotConfirmed.confirmationsRequired.shouldEqual(4)
        localNotConfirmed.remoteConfirmationsNeeded.shouldEqual(4)
        localNotConfirmed.fulfilled.shouldBeFalse()
        localNotConfirmed.remoteFailuresAllowed.shouldEqual(1) // 5 - 4 (needed)
    }

    func test_OperationExecution_consistency_quorum_throwIfNoRemoteMember() throws {
        let remoteMembersCount = 0

        let error = shouldThrow {
            _ = try OperationExecution<Int>(with: .quorum, remoteMembersCount: remoteMembersCount, localConfirmed: true)
        }

        guard case CRDT.OperationConsistency.Error.remoteReplicasRequired = error else {
            throw self.localTestKit.fail("Expected .remoteReplicasRequired, got \(error)")
        }
    }

    func test_OperationExecution_consistency_quorum_throwIfUnableToFulfill() throws {
        let remoteMembersCount = 1

        let error = shouldThrow {
            // Send false for `localConfirmed` so the operation cannot be fulfilled.
            _ = try OperationExecution<Int>(with: .quorum, remoteMembersCount: remoteMembersCount, localConfirmed: false)
        }

        guard case CRDT.OperationConsistency.Error.unableToFulfill(_, let localConfirmed, let required, let remaining, let obtainable) = error else {
            throw self.localTestKit.fail("Expected .unableToFulfill with required: 2, remaining: 2, obtainable: 1, got \(error)")
        }
        localConfirmed.shouldBeFalse()
        required.shouldEqual(2) // quorum = (1 + 1) / 2 + 1 = 2
        remaining.shouldEqual(2) // because localConfirmed = false
        obtainable.shouldEqual(1) // 1 remote
    }

    func test_OperationExecution_consistency_all() throws {
        let remoteMembersCount = 5

        let localConfirmed = try OperationExecution<Int>(with: .all, remoteMembersCount: remoteMembersCount, localConfirmed: true)
        localConfirmed.localConfirmed.shouldBeTrue()
        localConfirmed.confirmationsRequired.shouldEqual(6) // 5 + 1
        localConfirmed.remoteConfirmationsNeeded.shouldEqual(5)
        localConfirmed.fulfilled.shouldBeFalse()
        localConfirmed.remoteFailuresAllowed.shouldEqual(0) // 5 - 5 (needed)
        localConfirmed.failed.shouldBeFalse()
    }

    func test_OperationExecution_consistency_all_throwWhenLocalNotConfirmed() throws {
        let remoteMembersCount = 5

        let error = shouldThrow {
            // Send false for `localConfirmed` so the operation cannot be fulfilled.
            _ = try OperationExecution<Int>(with: .all, remoteMembersCount: remoteMembersCount, localConfirmed: false)
        }

        guard case CRDT.OperationConsistency.Error.unableToFulfill(_, let localConfirmed, let required, let remaining, let obtainable) = error else {
            throw self.localTestKit.fail("Expected .unableToFulfill with required: \(remoteMembersCount + 1), remaining: \(remoteMembersCount + 1), obtainable: \(remoteMembersCount), got \(error)")
        }
        localConfirmed.shouldBeFalse()
        required.shouldEqual(remoteMembersCount + 1) // remote + local
        remaining.shouldEqual(remoteMembersCount + 1) // because localConfirmed = false
        obtainable.shouldEqual(remoteMembersCount)
    }
}
