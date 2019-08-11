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

import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

// TODO: add tests for non-delta-CRDT
// TODO: add tests for non-local consistency level
// TODO: add test: `OwnerCommand.read` with non `.local` consistency level should notify owners

final class CRDTReplicationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    typealias OwnerProtocol = CRDT.ReplicatedDataOwnerProtocol

    typealias OwnerRegisterResult = CRDT.ReplicationProtocol.OwnerCommand.RegisterResult
    typealias OwnerWriteResult = CRDT.ReplicationProtocol.OwnerCommand.WriteResult
    typealias OwnerReadResult = CRDT.ReplicationProtocol.OwnerCommand.ReadResult
    typealias OwnerDeleteResult = CRDT.ReplicationProtocol.OwnerCommand.DeleteResult

    typealias ClusterWriteResult = CRDT.ReplicationProtocol.ClusterCommand.WriteResult
    typealias ClusterReadResult = CRDT.ReplicationProtocol.ClusterCommand.ReadResult
    typealias ClusterDeleteResult = CRDT.ReplicationProtocol.ClusterCommand.DeleteResult

    func test_ownerCommand_write_shouldUpdateDeltaCRDTInLocalStoreUsingMergeDelta_shouldNotifyOwners() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let registerP = testKit.spawnTestProbe(expecting: OwnerRegisterResult.self)
        let writeP = testKit.spawnTestProbe(expecting: OwnerWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: OwnerReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        // This owner sends commands to replicator
        let ownerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register owner with replicator
        replicator.tell(.ownerCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // This is *another* owner of the CRDT
        let anotherOwnerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register anotherOwner so replicator will notify it on CRDT updates
        replicator.tell(.ownerCommand(.register(ownerRef: anotherOwnerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // Tell replicator to write g1
        replicator.tell(.ownerCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, consistency: .local, ownerRef: ownerP.ref, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }
        // Reset g1's delta after write so that it will only contain the next mutation; then increment again
        g1.resetDelta()
        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        replicator.tell(.ownerCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, consistency: .local, ownerRef: ownerP.ref, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should have updated state via `mergeDelta`
        replicator.tell(.ownerCommand(.read(id: id, consistency: .local, ownerRef: ownerP.ref, replyTo: readP.ref)))
        // `read` returns the underlying CRDT
        guard case let .success(data) = try readP.expectMessage() else { throw readP.error() }

        guard let gg1 = data as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner and anotherOwner should have been notified twice because `write` was issued for g1 twice
        let notifiedOwnerProbes = [ownerP, anotherOwnerP]
        for op in notifiedOwnerProbes {
            let messages = try op.expectMessages(count: 2)
            // Take the last notification received and compare that against g1
            guard case let .updated(ud) = messages[1] else {
                throw self.testKit.fail("Should be .updated message")
            }
            // Should receive the latest g1
            guard let ugg1 = ud as? CRDT.GCounter else {
                throw self.testKit.fail(".updated message should include the underlying GCounter")
            }
            ugg1.value.shouldEqual(g1.value)
        }
    }

    func test_ownerCommand_delete_shouldRemoveFromLocalStore_shouldNotifyOwners() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let registerP = testKit.spawnTestProbe(expecting: OwnerRegisterResult.self)
        let writeP = testKit.spawnTestProbe(expecting: OwnerWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: OwnerReadResult.self)
        let deleteP = testKit.spawnTestProbe(expecting: OwnerDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        // This owner sends commands to replicator
        let ownerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register owner with replicator
        replicator.tell(.ownerCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // This is *another* owner of the CRDT
        let anotherOwnerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register anotherOwner so replicator will notify it on CRDT updates
        replicator.tell(.ownerCommand(.register(ownerRef: anotherOwnerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // Tell replicator to write g1
        replicator.tell(.ownerCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, consistency: .local, ownerRef: ownerP.ref, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // Tell replicator to delete g1
        replicator.tell(.ownerCommand(.delete(id: id, consistency: .local, ownerRef: ownerP.ref, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found in replicator
        replicator.tell(.ownerCommand(.read(id: id, consistency: .local, ownerRef: ownerP.ref, replyTo: readP.ref)))
        guard case let .failed(error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // owner and anotherOwner should have been notified twice because two commands (`write`, `delete`) were issued for g1
        let notifiedOwnerProbes = [ownerP, anotherOwnerP]
        for op in notifiedOwnerProbes {
            let messages = try op.expectMessages(count: 2)
            // The last notification should be `deleted`
            guard case .deleted = messages[1] else {
                throw self.testKit.fail("Should be .deleted message")
            }
        }
    }

    func test_clusterCommand_write_shouldUpdateCRDTInLocalStoreUsingMerge_shouldNotifyOwners() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let registerP = testKit.spawnTestProbe(expecting: OwnerRegisterResult.self)
        let writeP = testKit.spawnTestProbe(expecting: ClusterWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: ClusterReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        let ownerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register owner so replicator will notify it on CRDT updates
        replicator.tell(.ownerCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // Tell replicator to write g1
        replicator.tell(.clusterCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }
        // reset g1 delta after write so that it will only contain the next mutation then increment again
        g1.resetDelta()
        g1.increment(by: 10)

        // Tell replicator to write the updated g1
        replicator.tell(.clusterCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should have updated state via `merge`
        replicator.tell(.clusterCommand(.read(id: id, replyTo: readP.ref)))
        // `read` returns type-erased CRDT
        guard case let .success(data) = try readP.expectMessage() else { throw readP.error() }

        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner should have been notified twice because `write` was issued for g1 twice
        let messages = try ownerP.expectMessages(count: 2)
        // Take the last notification received and compare that against g1
        guard case let .updated(updatedData) = messages[1] else {
            throw self.testKit.fail("Should be .updated message")
        }
        // owner should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.testKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_clusterCommand_writeDelta_cannotAddUnknownDeltaCRDT() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let writeP = testKit.spawnTestProbe(expecting: ClusterWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: ClusterReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        // Ensure replicator doesn't know about g1
        replicator.tell(.clusterCommand(.read(id: id, replyTo: readP.ref)))
        guard case let .failed(readError) = try readP.expectMessage() else { throw readP.error() }
        readError.shouldEqual(.notFound)

        // Tell replicator to write g1.delta
        replicator.tell(.clusterCommand(.writeDelta(id: id, delta: g1.delta!.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case let .failed(writeError) = try writeP.expectMessage() else { throw writeP.error() }
        writeError.shouldEqual(.missingCRDTForDelta)
    }

    func test_clusterCommand_writeDelta_shouldUpdateDeltaCRDTInLocalStoreUsingMergeDelta_shouldNotifyOwners() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let registerP = testKit.spawnTestProbe(expecting: OwnerRegisterResult.self)
        let writeP = testKit.spawnTestProbe(expecting: ClusterWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: ClusterReadResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        let ownerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register owner so replicator will notify it on CRDT updates
        replicator.tell(.ownerCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // Tell replicator to write g1
        replicator.tell(.clusterCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }
        // reset g1 delta after write so that it will only contain the next mutation then increment again
        g1.resetDelta()
        g1.increment(by: 10)

        // Tell replicator to write g1.delta
        replicator.tell(.clusterCommand(.writeDelta(id: id, delta: g1.delta!.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // replicator's g1 should have updated state via `mergeDelta`
        replicator.tell(.clusterCommand(.read(id: id, replyTo: readP.ref)))
        // `read` returns type-erased CRDT
        guard case let .success(data) = try readP.expectMessage() else { throw readP.error() }

        guard let gg1 = data.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        gg1.value.shouldEqual(g1.value)

        // owner should have been notified twice because g1 was updated twice
        let messages = try ownerP.expectMessages(count: 2)
        // Take the last notification received and compare that against g1
        guard case let .updated(updatedData) = messages[1] else {
            throw self.testKit.fail("Should be .updated message")
        }
        // owner should receive the latest g1
        guard let ugg1 = updatedData as? CRDT.GCounter else {
            throw self.testKit.fail(".updated message should include the underlying GCounter")
        }
        ugg1.value.shouldEqual(g1.value)
    }

    func test_clusterCommand_delete_shouldRemoveFromLocalStore_shouldNotifyOwners() throws {
        let replicator = try system.spawn(CRDT.Replicator.behavior(), name: "replicator")
        let registerP = testKit.spawnTestProbe(expecting: OwnerRegisterResult.self)
        let writeP = testKit.spawnTestProbe(expecting: ClusterWriteResult.self)
        let readP = testKit.spawnTestProbe(expecting: ClusterReadResult.self)
        let deleteP = testKit.spawnTestProbe(expecting: ClusterDeleteResult.self)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(ownerAlpha))
        g1.increment(by: 1)

        let ownerP = testKit.spawnTestProbe(expecting: OwnerProtocol.self)
        // Register owner so replicator will notify it on CRDT updates
        replicator.tell(.ownerCommand(.register(ownerRef: ownerP.ref, id: id, data: g1.asAnyStateBasedCRDT, replyTo: registerP.ref)))

        // Tell replicator to write g1
        replicator.tell(.clusterCommand(.write(id: id, data: g1.asAnyStateBasedCRDT, replyTo: writeP.ref)))
        guard case .success = try writeP.expectMessage() else { throw writeP.error() }

        // Tell replicator to delete g1
        replicator.tell(.clusterCommand(.delete(id: id, replyTo: deleteP.ref)))
        guard case .success = try deleteP.expectMessage() else { throw deleteP.error() }

        // g1 should not be found in replicator
        replicator.tell(.clusterCommand(.read(id: id, replyTo: readP.ref)))
        guard case let .failed(error) = try readP.expectMessage() else { throw readP.error() }
        error.shouldEqual(.notFound)

        // owner should have been notified twice because two commands (`write`, `delete`) were issued for g1
        let messages = try ownerP.expectMessages(count: 2)
        // The last notification should be `deleted`
        guard case .deleted = messages[1] else {
            throw self.testKit.fail("Should be .deleted message")
        }
    }
}
