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

final class CRDTReplicatorInstanceTests: XCTestCase {
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

    func test_registerOwner_shouldAddActorRefToOwnersSetForCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let ownerP = self.testKit.spawnTestProbe(expecting: CRDT.Replication.DataOwnerMessage.self)
        let id = CRDT.Identity("test-data")

        // Ensure CRDT has no owner
        replicator.owners(for: id).shouldBeNil()

        // Register owner
        guard case .registered = replicator.registerOwner(dataId: id, owner: ownerP.ref) else {
            throw self.testKit.fail("Should be .registered")
        }

        // `owner` should be added after `registerOwner` call
        let owners = replicator.owners(for: id)
        owners.shouldNotBeNil()
        owners?.shouldContain(ownerP.ref)
    }

    func test_write_shouldAddCRDTToDataStoreIfNew_deltaMergeBoolNotApplicable() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 10)

        // Ensure g1 is not in data store
        guard case .notFound = replicator.read(id) else {
            throw self.testKit.fail("Data store should not have g1")
        }

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied(let writeResult, let isNew) = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeTrue()

        // Return value should match g1
        guard let wg1 = writeResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        // Delta is cleared before writing delta-CRDT to data store
        wg1.delta.shouldBeNil()
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.delta.shouldBeNil()
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldUpdateDeltaCRDTInDataStoreUsingMerge_whenDeltaMergeIsFalse() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)
        // Clear the delta; the full state should already contain the mutation so `merge` should yield correct result
        g1.resetDelta()

        // Write the updated g1
        guard case .applied(let writeResult, let isNew) = replicator.write(id, g1.asAnyStateBasedCRDT, deltaMerge: false) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeFalse()

        // Return value should match g1
        guard let wg1 = writeResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldUpdateDeltaCRDTInDataStoreUsingMergeDelta_whenDeltaMergeIsTrue() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // This should set g1's delta
        g1.increment(by: 10)
        g1.delta.shouldNotBeNil()

        // Write the updated g1
        guard case .applied(let writeResult, _) = replicator.write(id, g1.asAnyStateBasedCRDT, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldFallbackToMergeForDeltaCRDTIfDeltaIsNil_whenDeltaMergeIsTrue() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)
        // Reset g1's delta so that it is nil
        g1.resetDelta()

        // Write g1 with deltaMerge == true but g1.delta is nil; code should fallback to `merge`
        guard case .applied(let writeResult, _) = replicator.write(id, g1.asAnyStateBasedCRDT, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_mutationsByMultipleOwnersOfTheSameCRDT_shouldMergeCorrectly() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1Alpha = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1Alpha.increment(by: 1)
        var g1Beta = CRDT.GCounter(replicaId: .actorAddress(self.ownerBeta))
        g1Beta.increment(by: 10)

        // Write g1Alpha (as new so `deltaMerge` ignored)
        guard case .applied = replicator.write(id, g1Alpha.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        // Write g1Beta (with `mergeDelta`)
        guard case .applied(let bResult, _) = replicator.write(id, g1Beta.asAnyStateBasedCRDT, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value of the last write should equal g1Alpha and g1Beta combined
        guard let wg1 = bResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(11) // 1 + 10

        // Value in the data store should equal g1Alpha and g1Beta combined
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(11) // 1 + 10
    }

    func test_write_shouldFailWhenInputAndStoredTypeDoNotMatch() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // TODO: use real CRDT instead of mock
        let m1 = MockDeltaCRDT()
        // Cannot write data of different data under `id`
        guard case .inputAndStoredDataTypeMismatch(let stored) = replicator.write(id, m1.asAnyStateBasedCRDT, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have failed due to type mismatch")
        }
        // Stored data should be a gcounter
        g1.asAnyStateBasedCRDT.metaType.is(stored).shouldBeTrue()
    }

    func test_writeDelta_shouldFailIfCRDTIsNotInDataStore() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        guard case .missingCRDTForDelta = replicator.writeDelta(id, g1.delta!.asAnyStateBasedCRDT) else { // ! safe because `increment` should set `delta`
            throw self.testKit.fail("The writeDelta operation should have failed because CRDT does not exist")
        }
    }

    func test_writeDelta_shouldApplyDeltaToExistingDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 to data store
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)

        // Now write g1.delta
        guard case .applied(let writeResult) = replicator.writeDelta(id, g1.delta!.asAnyStateBasedCRDT) else { // ! safe because `increment` should set `delta`
            throw self.testKit.fail("The writeDelta operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult.underlying as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_writeDelta_shouldFailIfNotDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("mock-1")
        let m1 = MockCvRDT()

        // Write m1 to data store
        guard case .applied = replicator.write(id, m1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        guard case .cannotWriteDeltaForNonDeltaCRDT = replicator.writeDelta(id, m1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The writeDelta operation should have failed because m1 is not delta-CRDT")
        }
    }

    func test_read_shouldFailIfCRDTIsNotInDataStore() throws {
        let replicator = CRDT.Replicator.Instance(.default)
        let id = CRDT.Identity("test-data")

        guard case .notFound = replicator.read(id) else {
            throw self.testKit.fail("The read operation should return .notFound")
        }
    }

    func test_delete_shouldRemoveCRDTFromDataStore() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
        g1.increment(by: 1)

        // Write g1 to data store
        guard case .applied = replicator.write(id, g1.asAnyStateBasedCRDT) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Ensure g1 exists
        guard case .data = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }

        // Delete g1
        guard case .applied = replicator.delete(id) else {
            throw self.testKit.fail("The delete operation should have been applied")
        }

        // Ensure g1 no longer exists
        guard case .notFound = replicator.read(id) else {
            throw self.testKit.fail("g1 should have been deleted")
        }
    }
}
