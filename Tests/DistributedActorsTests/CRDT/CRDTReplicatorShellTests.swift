//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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
// TODO: add tests for non-local consistency level
// TODO: add test: `LocalCommand.read` with non `.local` consistency level should notify owners

final class CRDTReplicatorShellTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    typealias OwnerMessage = CRDT.Replication.DataOwnerMessage
    typealias LocalRegisterResult = CRDT.Replicator.LocalCommand.RegisterResult
    typealias LocalWriteResult = CRDT.Replicator.LocalCommand.WriteResult
    typealias LocalReadResult = CRDT.Replicator.LocalCommand.ReadResult
    typealias LocalDeleteResult = CRDT.Replicator.LocalCommand.DeleteResult
    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    typealias RemoteReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    typealias RemoteDeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult

    func test_localCommand_register_shouldAddActorRefToOwnersSet_shouldWriteCRDTToLocalStore() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)

        // Register the owner
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        // We can read g1 now because part of `register` command is writing g1 to local data store
        replicatorRef.tell(.localCommand(.read(id, consistency: .local, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1 = data as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)
    }

    func test_localCommand_write_localConsistency_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let writeP = self.testKit.spawnTestProbe(expecting: LocalWriteResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: LocalReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        // Mutate g1
        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        replicatorRef.tell(.localCommand(.write(id, g1.asAnyStateBasedCRDT, consistency: .local, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        replicatorRef.tell(.localCommand(.read(id, consistency: .local, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns the underlying CRDT
        guard let gg1 = data as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.testKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.testKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_localCommand_delete_localConsistency_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: LocalReadResult.self)
        let deleteP = self.testKit.spawnTestProbe(expecting: LocalDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 changes
        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        // Ensure g1 exists (it was written as part of `register`)
        replicatorRef.tell(.localCommand(.read(id, consistency: .local, replyTo: readP.ref)))
        guard case .success = try readP.expectMessage() else { throw readP.error() }

        // Tell replicator to delete g1
        replicatorRef.tell(.localCommand(.delete(id, consistency: .local, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found
        replicatorRef.tell(.localCommand(.read(id, consistency: .local, replyTo: readP.ref)))
        guard case .failed(let error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // owner should have been notified
        guard case .deleted = try ownerP.expectMessage() else {
            throw self.testKit.fail("Should be .deleted message")
        }
    }

    func test_remoteCommand_write_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let writeP = self.testKit.spawnTestProbe(expecting: RemoteWriteResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: RemoteReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        replicatorRef.tell(.remoteCommand(.write(id, g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        replicatorRef.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns type-erased CRDT
        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.testKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.testKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_remoteCommand_writeDelta_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let writeP = self.testKit.spawnTestProbe(expecting: RemoteWriteResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: RemoteReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 updates
        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        g1.increment(by: 10)

        // Tell replicator to write g1.delta
        replicatorRef.tell(.remoteCommand(.writeDelta(id, delta: g1.delta!.asAnyStateBasedCRDT, replyTo: writeP.ref))) // ! safe because `increment` should set `delta`
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should be updated
        replicatorRef.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success(let data) = try readP.expectMessage() else { throw readP.error() }

        // `read` returns type-erased CRDT
        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner should have been notified
        guard case .updated(let updatedData) = try ownerP.expectMessage() else {
            throw self.testKit.fail("Should be .updated message")
        }
        // Should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.testKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_remoteCommand_delete_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners() throws {
        let replicatorRef = try system.spawn("replicator", self.replicatorBehavior())
        let registerP = self.testKit.spawnTestProbe(expecting: LocalRegisterResult.self)
        let readP = self.testKit.spawnTestProbe(expecting: RemoteReadResult.self)
        let deleteP = self.testKit.spawnTestProbe(expecting: RemoteDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Register owner so replicator will notify it on g1 changes
        let ownerP = self.testKit.spawnTestProbe(expecting: OwnerMessage.self)
        replicatorRef.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        // Ensure g1 exists (it was written as part of `register`)
        replicatorRef.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .success = try readP.expectMessage() else { throw readP.error() }

        // Tell replicator to delete g1
        replicatorRef.tell(.remoteCommand(.delete(id, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found
        replicatorRef.tell(.remoteCommand(.read(id, replyTo: readP.ref)))
        guard case .failed(let error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // owner should have been notified
        guard case .deleted = try ownerP.expectMessage() else {
            throw self.testKit.fail("Should be .deleted message")
        }
    }

    func makeReplicator(configuredWith configure: (inout CRDT.Replicator.Settings) -> Void = { _ in }) -> CRDT.Replicator.Instance {
        var settings = CRDT.Replicator.Settings()
        configure(&settings)
        return CRDT.Replicator.Instance(settings)
    }

    func replicatorBehavior(configuredWith configure: @escaping (inout CRDT.Replicator.Settings) -> Void = { _ in }) -> Behavior<CRDT.Replicator.Message> {
        return .setup { _ in
            let replicator = self.makeReplicator(configuredWith: configure)
            return CRDT.Replicator.Shell(replicator).behavior
        }
    }
}
