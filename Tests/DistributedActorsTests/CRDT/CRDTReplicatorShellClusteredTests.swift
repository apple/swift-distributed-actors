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

final class CRDTReplicatorShellClusteredTests: ClusteredNodesTestBase {
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1 = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
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
        var g1Local = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaID: .actorAddress(self.ownerBeta))
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
        gg1Remote.state[g1Remote.replicaID]!.shouldEqual(3)
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

    func test_localCommand_write_localConsistency_remoteShouldEventuallyBeUpdated() throws {
        self.setUpLocal()
        self.setUpRemote()

        try self.joinNodes(node: self.localSystem, with: self.remoteSystem)
        try self.ensureNodes(.up, nodes: self.localSystem.cluster.node, self.remoteSystem.cluster.node)

        let writeP = self.localTestKit.spawnTestProbe(expecting: LocalWriteResult.self)
        let readP = self.localTestKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        // Local and remote have different versions of g1
        var g1Local = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaID: .actorAddress(self.ownerBeta))
        g1Remote.increment(by: 3)

        // Register owner so replicator will notify it on g1 updates
        let remoteOwnerP = try self.makeCRDTOwnerTestProbe(system: self.remoteSystem, testKit: self.remoteTestKit, id: id, data: g1Remote.asAnyStateBasedCRDT)

        // Tell local replicator to write g1. The `increment(by: 1)` change should be replicated to remote.
        self.localSystem.replicator.tell(.localCommand(.write(id, g1Local.asAnyStateBasedCRDT, consistency: .local, timeout: self.timeout, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // even through the write was .local, it should eventually reach the remote node via gossip
        let data: StateBasedCRDT = try remoteTestKit.eventually(within: .seconds(5)) {
            // Remote g1 should have the `increment(by: 1)` change
            self.remoteSystem.replicator.tell(.localCommand(.read(id, consistency: .local, timeout: self.timeout, replyTo: readP.ref)))
            guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }
            return data
        }

        // `read` returns the underlying CRDT
        guard let gg1Remote = data as? CRDT.GCounter else {
            throw self.localTestKit.fail("Should be a GCounter")
        }
        "\(gg1Remote.state)".shouldContain("/user/alpha: 1")
        gg1Remote.state[g1Remote.replicaID]!.shouldEqual(3)
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
        var g1Local = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaID: .actorAddress(self.ownerBeta))
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
        gg1Local.state[gg1Local.replicaID]!.shouldEqual(1)
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
        var g1Remote = CRDT.GCounter(replicaID: .actorAddress(self.ownerBeta))
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
        var g1Local = CRDT.GCounter(replicaID: .actorAddress(self.ownerAlpha))
        g1Local.increment(by: 1)
        var g1Remote = CRDT.GCounter(replicaID: .actorAddress(self.ownerBeta))
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
