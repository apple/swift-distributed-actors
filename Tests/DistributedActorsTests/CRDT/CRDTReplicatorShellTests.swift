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

// TODO: add tests for non-delta-CRDT

final class CRDTReplicatorShellTests: ClusteredNodesTestBase {
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
    // MARK: LocalCommand, .local consistency

    func test_localCommand_register_shouldAddActorRefToOwnersSet_shouldWriteCRDTToLocalStore() throws {
        self.setUpLocal()

        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register the owner
        _ = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        // We can read g1 now because part of `register` command is writing g1 to local data store
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1 = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)
    }

    func test_localCommand_write_localConsistency_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        self.setUpLocal()

        let writeP = self.localTestKit.spawnTestProbe(expecting: LocalWriteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        // Mutate g1
        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        self.localSystem.replicator.tell(.localCommand(.write(id, g1.asAnyStateBasedCRDT, consistency: .local, timeout: self.timeout, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1 = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // Owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.localTestKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_localCommand_delete_localConsistency_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners() throws {
        self.setUpLocal()

        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)
        let deleteP = self.localTestKit.spawnTestProbe(expecting: LocalDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 changes
        let ownerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        // Ensure g1 exists (it was written as part of `register`)
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .success = try readP.expectMessage() else { throw readP.error() }

        // Tell replicator to delete g1
        self.localSystem.replicator.tell(.localCommand(.delete(id, consistency: .local, timeout: self.timeout, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .failure(let error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // Owner should have been notified
        guard case .deleted = try ownerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .deleted message")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local receiving RemoteCommand

    func test_receive_remoteCommand_write_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        self.setUpLocal()

        let writeP = self.localTestKit.spawnTestProbe(expecting: RemoteWriteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: RemoteReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        self.localSystem.replicator.tell(.remoteCommand(.write(id, g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        self.localSystem.replicator.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns type-erased CRDT
        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // Owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.localTestKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_receive_remoteCommand_writeDelta_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        self.setUpLocal()

        let writeP = self.localTestKit.spawnTestProbe(expecting: RemoteWriteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: RemoteReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        g1.increment(by: 10)

        // Tell replicator to write g1.delta
        self.localSystem.replicator.tell(.remoteCommand(.writeDelta(id, delta: g1.delta!.asAnyStateBasedCRDT, replyTo: writeP.ref))) // ! safe because `increment` should set `delta`
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        self.localSystem.replicator.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns type-erased CRDT
        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // Owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.localTestKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_receive_remoteCommand_delete_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners() throws {
        self.setUpLocal()

        let readP = self.localTestKit.spawnTestProbe(expecting: RemoteReadResult.self)
        let deleteP = self.localTestKit.spawnTestProbe(expecting: RemoteDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 changes
        let ownerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1.asAnyStateBasedCRDT)

        // Ensure g1 exists (it was written as part of `register`)
        self.localSystem.replicator.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success = try readP.expectMessage() else { throw readP.error() }

        // Tell replicator to delete g1
        self.localSystem.replicator.tell(.remoteCommand(.delete(id, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found
        self.localSystem.replicator.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .failure(let error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // Owner should have been notified
        guard case .deleted = try ownerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .deleted message")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local command, non-local consistency

    func test_localCommand_write_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners() throws {
        self.setUpLocal()
        self.setUpRemote()

        try self.joinNodes(node: self.localSystem, with: self.remoteSystem)
        try self.ensureNodes(.up, nodes: self.localSystem.cluster.node, self.remoteSystem.cluster.node)

        let writeP = self.localTestKit.spawnTestProbe(expecting: LocalWriteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        // Local and remote have different versions of g1
        var g1Local = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g1Remote.increment(by: 3)

        // Register owner so replicator will notify it on g1 updates
        let remoteOwnerP = try self.makeCRDTOwnerTestProbe(system: self.remoteSystem, testKit: self.remoteTestKit, id: id, data: g1Remote.asAnyStateBasedCRDT)

        // Tell local replicator to write g1. The `increment(by: 1)` change should be replicated to remote.
        self.localSystem.replicator.tell(.localCommand(.write(id, g1Local.asAnyStateBasedCRDT, consistency: .all, timeout: self.timeout, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // Remote g1 should have the `increment(by: 1)` change
        self.remoteSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1Remote = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        "\(gg1Remote.state)".shouldContain("/user/alpha: 1")
        gg1Remote.state[g1Remote.replicaId]!.shouldEqual(3)
        gg1Remote.value.shouldEqual(4) // 1 + 3

        // Owner on remote node should have been notified
        guard case .updated(let updatedData) = try remoteOwnerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1Remote = updatedData as? CRDT.GCounter else {
            throw self.localTestKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1Remote.value.shouldEqual(gg1Remote.value)
    }

    func test_localCommand_read_allConsistency_shouldUpdateLocalStoreWithRemoteData_shouldNotifyOwners() throws {
        self.setUpLocal()
        self.setUpRemote()

        try self.joinNodes(node: self.localSystem, with: self.remoteSystem)
        try self.ensureNodes(.up, nodes: self.localSystem.cluster.node, self.remoteSystem.cluster.node)

        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        // Local and remote have different versions of g1
        var g1Local = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g1Remote.increment(by: 3)

        // Register owner so replicator has a copy of g1 and will notify the owner on g1 updates
        let localOwnerP = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1Local.asAnyStateBasedCRDT)
        _ = try self.makeCRDTOwnerTestProbe(system: self.remoteSystem, testKit: self.remoteTestKit, id: id, data: g1Remote.asAnyStateBasedCRDT)

        // Tell local replicator to read g1 with .all consistency. Remote copies of g1 should be merged with local.
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .all, timeout: self.timeout, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1Local = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        "\(gg1Local.state)".shouldContain("/user/beta: 3")
        gg1Local.state[gg1Local.replicaId]!.shouldEqual(1)
        gg1Local.value.shouldEqual(4) // 1 + 3

        // Local owner should have been notified
        guard case .updated(let updatedData) = try localOwnerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1Local = updatedData as? CRDT.GCounter else {
            throw self.localTestKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1Local.value.shouldEqual(gg1Local.value)
    }

    func test_localCommand_read_doesNotExistLocally_shouldBeOK_shouldUpdateLocalStoreWithRemoteData() throws {
        self.setUpLocal()
        self.setUpRemote()

        try self.joinNodes(node: self.localSystem, with: self.remoteSystem)
        try self.ensureNodes(.up, nodes: self.localSystem.cluster.node, self.remoteSystem.cluster.node)

        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        // g1 doesn't exist locally
        var g1Remote = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g1Remote.increment(by: 3)

        // Register owner so replicator has a copy of g1 and will notify the owner on g1 updates
        _ = try self.makeCRDTOwnerTestProbe(system: self.remoteSystem, testKit: self.remoteTestKit, id: id, data: g1Remote.asAnyStateBasedCRDT)

        // Tell local replicator to read g1 with .atLeast(1) consistency. Local doesn't have it but can be fulfilled
        // by remote instead. Remote copies of g1 should be merged with local.
        self.localSystem.replicator.tell(.localCommand(.read(id, consistency: .atLeast(1), timeout: self.timeout, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1Local = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        "\(gg1Local.state)".shouldContain("/user/beta: 3")
        gg1Local.value.shouldEqual(3) // contains data from remote g1 only

        // g1 not existing locally means it hasn't been registered and therefore there is no owner to notify
    }

    func test_localCommand_delete_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners() throws {
        self.setUpLocal()
        self.setUpRemote()

        try self.joinNodes(node: self.localSystem, with: self.remoteSystem)
        try self.ensureNodes(.up, nodes: self.localSystem.cluster.node, self.remoteSystem.cluster.node)

        let deleteP = self.localTestKit.spawnTestProbe(expecting: LocalDeleteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        // Local and remote have different versions of g1
        var g1Local = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g1Remote.increment(by: 3)

        // Register owner so replicator will notify it on g1 updates
        _ = try self.makeCRDTOwnerTestProbe(system: self.localSystem, testKit: self.localTestKit, id: id, data: g1Local.asAnyStateBasedCRDT)
        let remoteOwnerP = try self.makeCRDTOwnerTestProbe(system: self.remoteSystem, testKit: self.remoteTestKit, id: id, data: g1Remote.asAnyStateBasedCRDT)

        // Tell local replicator to delete g1
        self.localSystem.replicator.tell(.localCommand(.delete(id, consistency: .all, timeout: self.timeout, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should be deleted on remote node too
        self.remoteSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
        guard case .failure(let error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // Owner on remote node should have been notified
        guard case .deleted = try remoteOwnerP.expectMessage() else {
            throw self.localTestKit.fail("Should be .deleted message")
        }
    }

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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Test utilities

    private func makeCRDTOwnerTestProbe(system: ActorSystem, testKit: ActorTestKit, id: CRDT.Identity, data: AnyStateBasedCRDT) throws -> ActorTestProbe<OwnerMessage> {
        let ownerP = testKit.spawnTestProbe(expecting: OwnerMessage.self)
        let registerP = testKit.spawnTestProbe(expecting: LocalRegisterResult.self)

        // Register owner so replicator will notify it on CRDT updates
        system.replicator.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: data, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        return ownerP
    }
}
