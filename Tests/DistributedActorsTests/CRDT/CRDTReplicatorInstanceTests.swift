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

final class CRDTReplicatorInstanceTests: ActorSystemTestBase {
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

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
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 10)

        // Ensure g1 is not in data store
        guard case .notFound = replicator.read(id) else {
            throw self.testKit.fail("Data store should not have g1")
        }

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied(let writeResult, let isNew) = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeTrue()

        // Return value should match g1
        guard let wg1 = writeResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        // Delta is cleared before writing delta-CRDT to data store
        wg1.delta.shouldBeNil()
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.delta.shouldBeNil()
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldUpdateDeltaCRDTInDataStoreUsingMerge_whenDeltaMergeIsFalse() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)
        // Clear the delta; the full state should already contain the mutation so `merge` should yield correct result
        g1.resetDelta()

        // Write the updated g1
        guard case .applied(let writeResult, let isNew) = try replicator.write(id, g1, deltaMerge: false) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeFalse()

        // Return value should match g1
        guard let wg1 = writeResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldUpdateDeltaCRDTInDataStoreUsingMergeDelta_whenDeltaMergeIsTrue() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // This should set g1's delta
        g1.increment(by: 10)
        g1.delta.shouldNotBeNil()

        // Write the updated g1
        guard case .applied(let writeResult, _) = try replicator.write(id, g1, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_shouldFallbackToMergeForDeltaCRDTIfDeltaIsNil_whenDeltaMergeIsTrue() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)
        // Reset g1's delta so that it is nil
        g1.resetDelta()

        // Write g1 with deltaMerge == true but g1.delta is nil; code should fallback to `merge`
        guard case .applied(let writeResult, _) = try replicator.write(id, g1, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_write_mutationsByMultipleOwnersOfTheSameCRDT_shouldMergeCorrectly() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1Alpha = CRDT.GCounter(replicaId: self.replicaA)
        g1Alpha.increment(by: 1)
        var g1Beta = CRDT.GCounter(replicaId: self.replicaB)
        g1Beta.increment(by: 10)

        // Write g1Alpha (as new so `deltaMerge` ignored)
        guard case .applied = try replicator.write(id, g1Alpha) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        // Write g1Beta (with `mergeDelta`)
        guard case .applied(let bResult, _) = try replicator.write(id, g1Beta, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Return value of the last write should equal g1Alpha and g1Beta combined
        guard let wg1 = bResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(11) // 1 + 10

        // Value in the data store should equal g1Alpha and g1Beta combined
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(11) // 1 + 10
    }

    func test_write_shouldFailWhenInputAndStoredTypeDoNotMatch() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 (as new so `deltaMerge` ignored)
        guard case .applied = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        var s1 = CRDT.ORSet<Int>(replicaId: self.replicaA)
        s1.add(3)

        // Cannot write data of different data under `id`
        guard case .inputAndStoredDataTypeMismatch(let error) = try replicator.write(id, s1, deltaMerge: true) else {
            throw self.testKit.fail("The write operation should have failed due to type mismatch")
        }
        // Stored data should be a GCounter
        (error.storedType is CRDT.GCounter).shouldBeTrue()
    }

    func test_write_shouldAddCRDTToDataStoreIfNew_nonDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("lwwreg-1")
        let r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3)

        // Ensure r1 is not in data store
        guard case .notFound = replicator.read(id) else {
            throw self.testKit.fail("Data store should not have r1")
        }

        // Write r1
        guard case .applied(let writeResult, let isNew) = try replicator.write(id, r1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeTrue()

        // Return value should match r1
        guard let wr1 = writeResult as? CRDT.LWWRegister<Int> else {
            throw self.testKit.fail("Should be a LWWRegister<Int>")
        }
        wr1.value.shouldEqual(r1.value)

        // Value in the data store should also match r1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have r1")
        }
        guard let rr1 = readResult as? CRDT.LWWRegister<Int> else {
            throw self.testKit.fail("Should be a LWWRegister<Int>")
        }
        rr1.value.shouldEqual(r1.value)
    }

    func test_write_shouldUpdateCRDTInDataStoreUsingMerge_nonDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("lwwreg-1")
        let r1aClock = WallTimeClock()
        let r1a = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3, clock: .wallTime(r1aClock))

        // Write r1
        guard case .applied = try replicator.write(id, r1a) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        // Make sure the new value has a more recent timestamp for it to "win" the merge
        let r1b = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 5, clock: .wallTime(WallTimeClock(timestamp: r1aClock.timestamp.addingTimeInterval(1))))

        // Write the updated r1
        guard case .applied(let writeResult, let isNew) = try replicator.write(id, r1b) else {
            throw self.testKit.fail("The write operation should have been applied")
        }
        isNew.shouldBeFalse()

        // Return value should match r1b
        guard let wr1 = writeResult as? CRDT.LWWRegister<Int> else {
            throw self.testKit.fail("Should be a LWWRegister<Int>")
        }
        wr1.value.shouldEqual(r1b.value)

        // Value in the data store should also match r1b
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have r1b")
        }
        guard let rr1 = readResult as? CRDT.LWWRegister<Int> else {
            throw self.testKit.fail("Should be a LWWRegister<Int>")
        }
        rr1.value.shouldEqual(r1b.value)
    }

    func test_writeDelta_shouldFailIfCRDTIsNotInDataStore() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        guard case .missingCRDTForDelta = replicator.writeDelta(id, g1.delta!) else { // ! safe because `increment` should set `delta`
            throw self.testKit.fail("The writeDelta operation should have failed because CRDT does not exist")
        }
    }

    func test_writeDelta_shouldApplyDeltaToExistingDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("gcounter-1")
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 to data store
        guard case .applied = try replicator.write(id, g1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        g1.increment(by: 10)

        // Now write g1.delta
        guard case .applied(let writeResult) = replicator.writeDelta(id, g1.delta!) else { // ! safe because `increment` should set `delta`
            throw self.testKit.fail("The writeDelta operation should have been applied")
        }

        // Return value should match g1
        guard let wg1 = writeResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        wg1.value.shouldEqual(g1.value)

        // Value in the data store should also match g1
        guard case .data(let readResult) = replicator.read(id) else {
            throw self.testKit.fail("Data store should have g1")
        }
        guard let rg1 = readResult as? CRDT.GCounter else {
            throw self.testKit.fail("Should be a GCounter")
        }
        rg1.value.shouldEqual(g1.value)
    }

    func test_writeDelta_shouldFailIfNotDeltaCRDT() throws {
        let replicator = CRDT.Replicator.Instance(.default)

        let id = CRDT.Identity("lwwreg-1")
        let r1 = CRDT.LWWRegister<Int>(replicaId: self.replicaA, initialValue: 3)

        // Write r1 to data store
        guard case .applied = try replicator.write(id, r1) else {
            throw self.testKit.fail("The write operation should have been applied")
        }

        guard case .cannotWriteDeltaForNonDeltaCRDT = replicator.writeDelta(id, r1) else {
            throw self.testKit.fail("The writeDelta operation should have failed because r1 is not delta-CRDT")
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
        var g1 = CRDT.GCounter(replicaId: self.replicaA)
        g1.increment(by: 1)

        // Write g1 to data store
        guard case .applied = try replicator.write(id, g1) else {
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
