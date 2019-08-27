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

final class CRDTVersioningTests: XCTestCase {
    let replicaA: CRDT.ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .perpetual))
    let replicaB: CRDT.ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .perpetual))
    let replicaC: CRDT.ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("c"), incarnation: .perpetual))

    private typealias IntContainer = CRDT.VersionedContainer<Int>

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: VersionContext tests

    func test_VersionContext_add_then_compact() throws {
        // Comment on the right indicates outcome of `compact`
        let dot1 = Dot(replicaA, 2) // Should be added to vv
        let dot2 = Dot(replicaA, 3) // Should be added to vv
        let dot3 = Dot(replicaA, 5) // Should not be added to vv because of gap (4)
        let dot4 = Dot(replicaB, 1) // Should be added to vv because it follows version 0
        let dot5 = Dot(replicaC, 2) // Should be dropped because vv already contains version 2
        let dot6 = Dot(replicaC, 3) // Should be dropped because vv already contains version 3
        let dot7 = Dot(replicaB, 3) // To be added later
        let dot8 = Dot(replicaB, 2) // To be added later
        var versionContext = CRDT.VersionContext(vv: VersionVector([(replicaA, 1), (replicaC, 3)]), gaps: [dot1, dot2, dot3, dot4, dot5, dot6])

        versionContext.contains(dot3).shouldBeTrue() // `dots` contains dot3
        versionContext.contains(dot7).shouldBeFalse() // `dots` does not contain dot7
        versionContext.contains(Dot(self.replicaC, 2)).shouldBeTrue() // 3 ≥ 2
        versionContext.contains(Dot(self.replicaC, 5)).shouldBeFalse() // 3 ≱ 5

        // `add` then `compact`
        versionContext.add(dot7) // Should not be added to vv because of gap (2)
        versionContext.compact()
        versionContext.gaps.shouldEqual([dot3, dot7])
        versionContext.vv[replicaA].shouldEqual(3) // "A" continuous up to 3 after adding dot1, dot2
        versionContext.vv[replicaB].shouldEqual(1) // "B" continuous up to 1 after adding dot4
        versionContext.vv[replicaC].shouldEqual(3) // "C" continuous up to 3; dot5 and dot6 dropped

        // `add` then `compact`
        versionContext.add(dot8) // Should be added to vv and lead dot3 to be added too because gap (2) is filled
        versionContext.compact()
        versionContext.gaps.shouldEqual([dot3])
        versionContext.vv[replicaA].shouldEqual(3) // No change
        versionContext.vv[replicaB].shouldEqual(3) // "B" continuous up to 3 after adding dot7, dot8
        versionContext.vv[replicaC].shouldEqual(3) // No change
    }

    func test_VersionContext_merge_then_compact() throws {
        let dot1 = Dot(replicaA, 2)
        let dot2 = Dot(replicaA, 3)
        let dot3 = Dot(replicaA, 5)
        let dot4 = Dot(replicaB, 1)
        let dot5 = Dot(replicaC, 2)
        let dot6 = Dot(replicaC, 3)
        let dot7 = Dot(replicaB, 3)
        let dot8 = Dot(replicaB, 2)
        var versionContext1 = CRDT.VersionContext(vv: VersionVector([(replicaA, 1), (replicaC, 3)]), gaps: [dot1, dot4, dot5, dot6, dot8])
        let versionContext2 = CRDT.VersionContext(vv: VersionVector([(replicaB, 1), (replicaC, 4)]), gaps: [dot2, dot3, dot7])

        // `merge` mutates versionContext1; then call `compact`
        versionContext1.merge(other: versionContext2)
        versionContext1.compact()
        versionContext1.gaps.shouldEqual([dot3]) // Should not be added to vv because of gap (4)
        versionContext1.vv[replicaA].shouldEqual(3) // "A" continuous up to 3 with dot1, dot2
        versionContext1.vv[replicaB].shouldEqual(3) // "B" continuous up to 3 with dot7, dot8
        versionContext1.vv[replicaC].shouldEqual(4) // "C" continuous up to 4 (from versionContext2.vv); dot5 and dot6 dropped

        // versionContext2 should not be mutated
        versionContext2.gaps.shouldEqual([dot2, dot3, dot7])
        versionContext2.vv[replicaA].shouldEqual(0)
        versionContext2.vv[replicaB].shouldEqual(1)
        versionContext2.vv[replicaC].shouldEqual(4)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: VersionedContainer tests

    func test_VersionedContainer_add_remove_shouldModifyDelta() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        aContainer.isEmpty.shouldBeTrue()

        aContainer.add(3)
        aContainer.elements.shouldEqual([3])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,1): 3], vv=[(A,1)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(1) // The container's vv should be incremented (0 -> 1)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(3) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3], vv=[(A,1)], gaps=[]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv[replicaA].shouldEqual(1) // The delta's vv should be incremented (0 -> 1) because of `compact`
        aContainer.delta!.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 0 -> 1 is contiguous
        aContainer.delta!.elementByBirthDot.count.shouldEqual(1)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(3) // Delta should also have the dot

        aContainer.add(5)
        aContainer.elements.shouldEqual([3, 5])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,1): 3, (A,2): 5], vv=[(A,2)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(2) // The container's vv should be incremented (1 -> 2)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[Dot(replicaA, 2)]!.shouldEqual(5) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3, (A,2): 5], vv=[(A,1)], gaps=[]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv[replicaA].shouldEqual(2) // The delta's vv should be incremented (1 -> 2) because of `compact`
        aContainer.delta!.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 1 -> 2 is contiguous
        aContainer.delta!.elementByBirthDot.count.shouldEqual(2)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 2)]!.shouldEqual(5) // Delta should also have the dot

        // Add 3 again
        aContainer.add(3)
        aContainer.elements.shouldEqual([3, 5])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,1): 3, (A,2): 5, (A,3): 3], vv=[(A,3)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(3) // The container's vv should be incremented (2 -> 3)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(3)
        aContainer.elementByBirthDot[Dot(replicaA, 3)]!.shouldEqual(3) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3, (A,2): 5], (A,3): 3], vv=[(A,3)], gaps=[]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv[replicaA].shouldEqual(3) // The delta's vv should be incremented (2 -> 3) because of `compact`
        aContainer.delta!.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 2 -> 3 is contiguous
        aContainer.delta!.elementByBirthDot.count.shouldEqual(3)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 3)]!.shouldEqual(3) // Delta should also have the dot

        aContainer.remove(3)
        aContainer.elements.shouldEqual([5])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 5], vv=[(A,3)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(3) // `remove` doesn't change vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Removed dots are added to delta, not container's versionContext.gaps
        aContainer.elementByBirthDot.count.shouldEqual(1) // (A,1) and (A,3) removed; 3 - 2 = 1
        // delta: elementByBirthDot=[(A,2): 5], vv=[(A,3)], gaps=[]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv[replicaA].shouldEqual(3) // `remove` doesn't change vv
        aContainer.delta!.versionContext.gaps.isEmpty.shouldBeTrue() // (A,1) and (A,3) added to gaps but dropped since vv already contains them
        aContainer.delta!.elementByBirthDot.count.shouldEqual(1)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 1)].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 3)].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted

        aContainer.resetDelta()
        aContainer.delta.shouldBeNil()

        // `resetDelta` doesn't affect container's elementByBirthDot or versionContext
        aContainer.add(6)
        aContainer.elements.shouldEqual([5, 6])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 5, (A,4): 6], vv=[(A,4)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(4) // The container's vv should be incremented (3 -> 4)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[Dot(replicaA, 4)]!.shouldEqual(6) // Verify birth dot
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4)]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv.isEmpty.shouldBeTrue() // New dot is non-contiguous (vv version is 0, new dot's version is 4) so `compact` doesn't add to vv
        aContainer.delta!.versionContext.gaps.count.shouldEqual(1) // Dot was added to gaps and `compact` can't merge it to vv
        aContainer.delta!.versionContext.gaps.contains(Dot(self.replicaA, 4)).shouldBeTrue()
        aContainer.delta!.elementByBirthDot.count.shouldEqual(1)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 4)]!.shouldEqual(6) // Delta should also have the dot

        aContainer.remove(5)
        aContainer.elements.shouldEqual([6])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,4): 6], vv=[(A,4)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(4) // `remove` doesn't change vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Removed dots are added to delta, not container's versionContext.gaps
        aContainer.elementByBirthDot.count.shouldEqual(1) // (A,2) removed; 2 - 1 = 1
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4), (A,2)]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv.isEmpty.shouldBeTrue() // (A,2) non-contiguous so `compact` doesn't add to vv
        aContainer.delta!.versionContext.gaps.count.shouldEqual(2) // Dot was added to gaps and `compact` can't merge it to vv
        aContainer.delta!.versionContext.gaps.contains(Dot(self.replicaA, 2)).shouldBeTrue()
        aContainer.delta!.elementByBirthDot.count.shouldEqual(1)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 2)].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted
    }

    func test_VersionedContainer_removeAll_shouldAddAllBirthDotsToDeltaVersionContext() throws {
        let versionContext = CRDT.VersionContext(vv: VersionVector([(replicaA, 3), (replicaB, 1)]), gaps: [Dot(replicaB, 5)])
        var aContainer = IntContainer(replicaId: replicaA, versionContext: versionContext, elementByBirthDot: [Dot(replicaA, 2): 4])

        // container: elementByBirthDot=[(A,2): 4], vv=[(A,3), (B,1)], gaps=[(B,5)]
        aContainer.elements.shouldEqual([4])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        aContainer.versionContext.vv[replicaA].shouldEqual(3)
        aContainer.versionContext.vv[replicaB].shouldEqual(1)
        aContainer.versionContext.gaps.count.shouldEqual(1) // (B,5)
        aContainer.elementByBirthDot.count.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 2)].shouldEqual(4)
        aContainer.delta.shouldBeNil()

        aContainer.add(6)
        aContainer.elements.shouldEqual([4, 6])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 4, (A,4): 6], vv=[(A,4), (B,1)], gaps=[(B,5)]
        aContainer.versionContext.vv[replicaA].shouldEqual(4) // The container's vv should be incremented (3 -> 4)
        aContainer.versionContext.vv[replicaB].shouldEqual(1) // Another replica's version untouched
        aContainer.versionContext.gaps.count.shouldEqual(1) // (B,5)
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[Dot(replicaA, 4)]!.shouldEqual(6) // Verify birth dot
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4)]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv.isEmpty.shouldBeTrue() // New dot is non-contiguous (vv version is 0, new dot's version is 4) so `compact` doesn't add to vv
        aContainer.delta!.versionContext.gaps.count.shouldEqual(1) // Dot was added to gaps and `compact` can't merge it to vv
        aContainer.delta!.versionContext.gaps.contains(Dot(self.replicaA, 4)).shouldBeTrue()
        aContainer.delta!.elementByBirthDot.count.shouldEqual(1)
        aContainer.delta!.elementByBirthDot[Dot(replicaA, 4)]!.shouldEqual(6) // Delta should also have the dot

        // Remove all elements!
        aContainer.removeAll()

        // container: elementByBirthDot=[], vv=[(A,4), (B,1)], gaps=[(B,5)]
        aContainer.elements.isEmpty.shouldBeTrue() // Elements deleted
        aContainer.count.shouldEqual(0)
        aContainer.isEmpty.shouldBeTrue()
        aContainer.versionContext.vv[replicaA].shouldEqual(4) // `removeAll` doesn't change container vv
        aContainer.versionContext.vv[replicaB].shouldEqual(1) // Another replica's version untouched
        aContainer.versionContext.gaps.count.shouldEqual(1) // `removeAll` doesn't change container gaps
        aContainer.elementByBirthDot.isEmpty.shouldBeTrue()
        // delta: elementByBirthDot=[], vv=[], gaps=[(A,4), (A,2)]
        aContainer.delta.shouldNotBeNil() // Delta should be set
        aContainer.delta!.versionContext.vv.isEmpty.shouldBeTrue() // `removeAll` doesn't change delta vv
        aContainer.delta!.versionContext.gaps.count.shouldEqual(2)
        aContainer.delta!.versionContext.gaps.contains(Dot(self.replicaA, 4)).shouldBeTrue()
        aContainer.delta!.versionContext.gaps.contains(Dot(self.replicaA, 2)).shouldBeTrue() // (A,2) was added to delta gaps
        aContainer.delta!.elementByBirthDot.isEmpty.shouldBeTrue() // Dots not in delta.elementByBirthDot indicates elements are deleted
    }

    func test_VersionedContainer_merge_replicaBHasElementsThatReplicaAHasNotSeen_replicaAShouldAdd() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        var bContainer = IntContainer(replicaId: replicaB)

        aContainer.add(1)
        aContainer.add(3)
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]

        bContainer.add(3)
        bContainer.add(4)
        // bContainer: elementByBirthDot=[(B,1): 3, (B,2): 4], vv=[(B,2)], gaps=[]

        // `merge` mutates aContainer
        aContainer.merge(other: bContainer)
        aContainer.elements.shouldEqual([1, 3, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(2)
        aContainer.versionContext.vv[replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 2)]!.shouldEqual(3)
        aContainer.elementByBirthDot[Dot(replicaB, 1)]!.shouldEqual(3) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.elementByBirthDot[Dot(replicaB, 2)]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.delta.shouldBeNil() // delta cleared after `merge`
    }

    func test_VersionedContainer_merge_replicaBHasRemovalsThatReplicaAHasNotSeen_replicaAShouldDelete() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        var bContainer = IntContainer(replicaId: replicaB)

        aContainer.add(1)
        aContainer.add(3)
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]

        bContainer.add(3)
        // bContainer: elementByBirthDot=[(B,1): 3], vv=[(B,1)], gaps=[]

        // Merge aContainer into bContainer so that the latter's version context dominates
        bContainer.merge(other: aContainer)
        // bContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3], vv=[(A,2), (B,1)], gaps=[]

        bContainer.remove(3)
        // bContainer: elementByBirthDot=[(A,1): 1], vv=[(A,2), (B,1)], gaps=[]; delta: elementByBirthDot=[], vv=[(B,1)], gaps=[(A,2)]
        bContainer.add(4)
        // bContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]; delta: elementByBirthDot=[(B,2): 4], vv=[(B,2)], gaps=[(A,2)]

        // `merge` mutates aContainer
        aContainer.merge(other: bContainer)
        aContainer.elements.shouldEqual([1, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(2)
        aContainer.versionContext.vv[replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 2)].shouldBeNil() // (A,2): 3 deleted in B and B's version context dominates A's, so A deleted it
        aContainer.elementByBirthDot[Dot(replicaB, 1)].shouldBeNil() // (B,1): 3 deleted in B; A didn't see this
        aContainer.elementByBirthDot[Dot(replicaB, 2)]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.delta.shouldBeNil() // delta cleared after `merge`
    }

    func test_VersionedContainer_merge_twoReplicasFormCompleteHistory() throws {
        let aVersionContext = CRDT.VersionContext(vv: VersionVector([(replicaA, 3), (replicaB, 1), (replicaC, 1)]), gaps: [Dot(replicaC, 4), Dot(replicaC, 5)])
        var aContainer = IntContainer(replicaId: replicaA, versionContext: aVersionContext, elementByBirthDot: [Dot(replicaA, 2): 4, Dot(replicaC, 4): 0, Dot(replicaC, 5): 3])

        let bVersionContext = CRDT.VersionContext(vv: VersionVector([(replicaA, 3), (replicaB, 1)]), gaps: [Dot(replicaC, 2), Dot(replicaC, 3)])
        let bContainer = IntContainer(replicaId: replicaB, versionContext: bVersionContext, elementByBirthDot: [Dot(replicaA, 2): 4, Dot(replicaC, 3): 7])

        // `merge` mutates aContainer
        aContainer.merge(other: bContainer)
        aContainer.elements.shouldEqual([4, 7, 0, 3])
        // aContainer: elementByBirthDot=[(A,2): 4, (C,3): 7, (C,4): 0, (C,5): 3], vv=[(A,3), (B,1), (C,5)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(3)
        aContainer.versionContext.vv[replicaB].shouldEqual(1)
        aContainer.versionContext.vv[replicaC].shouldEqual(5) // (C,2) and (C,3) from B filled the gaps and `compact` merged (C,4) and (C,5) to vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // ^^
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[Dot(replicaA, 2)]!.shouldEqual(4)
        aContainer.elementByBirthDot[Dot(replicaC, 3)]!.shouldEqual(7)
        aContainer.elementByBirthDot[Dot(replicaC, 4)]!.shouldEqual(0)
        aContainer.elementByBirthDot[Dot(replicaC, 5)]!.shouldEqual(3)
        aContainer.delta.shouldBeNil() // delta cleared after `merge`
    }

    func test_VersionedContainer_mergeDelta_replicaBHasElementsThatReplicaAHasNotSeen_replicaAShouldAdd() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        var bContainer = IntContainer(replicaId: replicaB)

        aContainer.add(1)
        aContainer.add(3)
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]; delta: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]

        bContainer.add(3)
        bContainer.add(4)
        // bContainer: elementByBirthDot=[(B,1): 3, (B,2): 4], vv=[(B,2)], gaps=[]; delta: elementByBirthDot=[(B,1): 3, (B,2): 4], vv=[(B,2)], gaps=[]
        bContainer.delta.shouldNotBeNil()

        // `mergeDelta` mutates aContainer
        aContainer.mergeDelta(bContainer.delta!)
        aContainer.elements.shouldEqual([1, 3, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(2)
        aContainer.versionContext.vv[replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 2)]!.shouldEqual(3)
        aContainer.elementByBirthDot[Dot(replicaB, 1)]!.shouldEqual(3) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.elementByBirthDot[Dot(replicaB, 2)]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.delta.shouldBeNil() // delta cleared after `merge`
    }

    func test_VersionedContainer_mergeDelta_replicaBHasRemovalsThatReplicaAHasNotSeen_replicaAShouldDelete() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        var bContainer = IntContainer(replicaId: replicaB)

        aContainer.add(1)
        aContainer.add(3)
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]; delta: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]
        aContainer.delta.shouldNotBeNil()

        bContainer.add(3)
        // bContainer: elementByBirthDot=[(B,1): 3], vv=[(B,1)], gaps=[]

        // Merge aContainer.delta into bContainer so that the latter's version context dominates
        bContainer.mergeDelta(aContainer.delta!)
        bContainer.delta.shouldBeNil() // delta cleared after `mergeDelta`
        // bContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3], vv=[(A,2), (B,1)], gaps=[]

        bContainer.remove(3)
        // bContainer: elementByBirthDot=[(A,1): 1], vv=[(A,2), (B,1)], gaps=[]; delta: elementByBirthDot=[], vv=[(B,1)], gaps=[(A,2)]
        bContainer.add(4)
        // bContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]; delta: elementByBirthDot=[(B,2): 4], vv=[(B,2)], gaps=[(A,2)]
        bContainer.delta.shouldNotBeNil()

        // `mergeDelta` mutates aContainer
        aContainer.mergeDelta(bContainer.delta!)
        aContainer.elements.shouldEqual([1, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[replicaA].shouldEqual(2)
        aContainer.versionContext.vv[replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[Dot(replicaA, 1)]!.shouldEqual(1)
        aContainer.elementByBirthDot[Dot(replicaA, 2)].shouldBeNil() // (A,2): 3 deleted in B and B's version context dominates A's, so A deleted it
        aContainer.elementByBirthDot[Dot(replicaB, 1)].shouldBeNil() // (B,1): 3 deleted in B; A didn't see this
        aContainer.elementByBirthDot[Dot(replicaB, 2)]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.delta.shouldBeNil() // delta cleared after `mergeDelta`
    }
}
