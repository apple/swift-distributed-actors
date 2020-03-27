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
    typealias V = UInt64

    let replicaA: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))
    let replicaC: ReplicaID = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("c"), incarnation: .wellKnown))

    private typealias IntContainer = CRDT.VersionedContainer<Int>

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: VersionContext tests

    func test_VersionContext_add_then_compact() throws {
        // Comment on the right indicates outcome of `compact`
        let dot1 = VersionDot(replicaA, V(2)) // Should be added to vv
        let dot2 = VersionDot(replicaA, V(3)) // Should be added to vv
        let dot3 = VersionDot(replicaA, V(5)) // Should not be added to vv because of gap (4)
        let dot4 = VersionDot(replicaB, V(1)) // Should be added to vv because it follows version 0
        let dot5 = VersionDot(replicaC, V(2)) // Should be dropped because vv already contains version 2
        let dot6 = VersionDot(replicaC, V(3)) // Should be dropped because vv already contains version 3
        let dot7 = VersionDot(replicaB, V(3)) // To be added later
        let dot8 = VersionDot(replicaB, V(2)) // To be added later
        var versionContext = CRDT.VersionContext(vv: VersionVector([(self.replicaA, V(1)), (self.replicaC, V(3))]), gaps: [dot1, dot2, dot3, dot4, dot5, dot6])

        versionContext.contains(dot3).shouldBeTrue() // `dots` contains dot3
        versionContext.contains(dot7).shouldBeFalse() // `dots` does not contain dot7
        versionContext.contains(VersionDot(self.replicaC, 2)).shouldBeTrue() // 3 ≥ 2
        versionContext.contains(VersionDot(self.replicaC, 5)).shouldBeFalse() // 3 ≱ 5

        // `add` then `compact`
        versionContext.add(dot7) // Should not be added to vv because of gap (2)
        versionContext.compact()
        versionContext.gaps.shouldEqual([dot3, dot7])
        versionContext.vv[self.replicaA].shouldEqual(3) // "A" continuous up to 3 after adding dot1, dot2
        versionContext.vv[self.replicaB].shouldEqual(1) // "B" continuous up to 1 after adding dot4
        versionContext.vv[self.replicaC].shouldEqual(3) // "C" continuous up to 3; dot5 and dot6 dropped

        // `add` then `compact`
        versionContext.add(dot8) // Should be added to vv and lead dot3 to be added too because gap (2) is filled
        versionContext.compact()
        versionContext.gaps.shouldEqual([dot3])
        versionContext.vv[self.replicaA].shouldEqual(3) // No change
        versionContext.vv[self.replicaB].shouldEqual(3) // "B" continuous up to 3 after adding dot7, dot8
        versionContext.vv[self.replicaC].shouldEqual(3) // No change
    }

    func test_VersionContext_merge_then_compact() throws {
        let dot1 = VersionDot(replicaA, V(2))
        let dot2 = VersionDot(replicaA, V(3))
        let dot3 = VersionDot(replicaA, V(5))
        let dot4 = VersionDot(replicaB, V(1))
        let dot5 = VersionDot(replicaC, V(2))
        let dot6 = VersionDot(replicaC, V(3))
        let dot7 = VersionDot(replicaB, V(3))
        let dot8 = VersionDot(replicaB, V(2))
        var versionContext1 = CRDT.VersionContext(vv: VersionVector([(self.replicaA, V(1)), (self.replicaC, V(3))]), gaps: [dot1, dot4, dot5, dot6, dot8])
        let versionContext2 = CRDT.VersionContext(vv: VersionVector([(self.replicaB, V(1)), (self.replicaC, V(4))]), gaps: [dot2, dot3, dot7])

        // `merge` mutates versionContext1; then call `compact`
        versionContext1.merge(other: versionContext2)
        versionContext1.compact()
        versionContext1.gaps.shouldEqual([dot3]) // Should not be added to vv because of gap (4)
        versionContext1.vv[self.replicaA].shouldEqual(3) // "A" continuous up to 3 with dot1, dot2
        versionContext1.vv[self.replicaB].shouldEqual(3) // "B" continuous up to 3 with dot7, dot8
        versionContext1.vv[self.replicaC].shouldEqual(4) // "C" continuous up to 4 (from versionContext2.vv); dot5 and dot6 dropped

        // versionContext2 should not be mutated
        versionContext2.gaps.shouldEqual([dot2, dot3, dot7])
        versionContext2.vv[self.replicaA].shouldEqual(0)
        versionContext2.vv[self.replicaB].shouldEqual(1)
        versionContext2.vv[self.replicaC].shouldEqual(4)
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
        aContainer.versionContext.vv[self.replicaA].shouldEqual(1) // The container's vv should be incremented (0 -> 1)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(3) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3], vv=[(A,1)], gaps=[]
        guard let d1 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d1.versionContext.vv[self.replicaA].shouldEqual(1) // The delta's vv should be incremented (0 -> 1) because of `compact`
        d1.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 0 -> 1 is contiguous
        d1.elementByBirthDot.count.shouldEqual(1)
        d1.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(3) // Delta should also have the dot
        d1.elements.shouldEqual([3])

        aContainer.add(5)
        aContainer.elements.shouldEqual([3, 5])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,1): 3, (A,2): 5], vv=[(A,2)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(2) // The container's vv should be incremented (1 -> 2)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))]!.shouldEqual(5) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3, (A,2): 5], vv=[(A,1)], gaps=[]
        guard let d2 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d2.versionContext.vv[self.replicaA].shouldEqual(2) // The delta's vv should be incremented (1 -> 2) because of `compact`
        d2.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 1 -> 2 is contiguous
        d2.elementByBirthDot.count.shouldEqual(2)
        d2.elementByBirthDot[VersionDot(self.replicaA, V(2))]!.shouldEqual(5) // Delta should also have the dot
        d2.elements.shouldEqual([3, 5])

        // Add 3 again
        aContainer.add(3)
        aContainer.elements.shouldEqual([3, 5])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,1): 3, (A,2): 5, (A,3): 3], vv=[(A,3)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(3) // The container's vv should be incremented (2 -> 3)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(3)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(3))]!.shouldEqual(3) // Verify birth dot
        // delta: elementByBirthDot=[(A,1): 3, (A,2): 5], (A,3): 3], vv=[(A,3)], gaps=[]
        guard let d3 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d3.versionContext.vv[self.replicaA].shouldEqual(3) // The delta's vv should be incremented (2 -> 3) because of `compact`
        d3.versionContext.gaps.isEmpty.shouldBeTrue() // Dot was added to gaps but merged to vv since 2 -> 3 is contiguous
        d3.elementByBirthDot.count.shouldEqual(3)
        d3.elementByBirthDot[VersionDot(self.replicaA, V(3))]!.shouldEqual(3) // Delta should also have the dot
        d3.elements.shouldEqual([3, 5])

        aContainer.remove(3)
        aContainer.elements.shouldEqual([5])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 5], vv=[(A,3)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(3) // `remove` doesn't change vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Removed dots are added to delta, not container's versionContext.gaps
        aContainer.elementByBirthDot.count.shouldEqual(1) // (A,1) and (A,3) removed; 3 - 2 = 1
        // delta: elementByBirthDot=[(A,2): 5], vv=[(A,3)], gaps=[]
        guard let d4 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d4.versionContext.vv[self.replicaA].shouldEqual(3) // `remove` doesn't change vv
        d4.versionContext.gaps.isEmpty.shouldBeTrue() // (A,1) and (A,3) added to gaps but dropped since vv already contains them
        d4.elementByBirthDot.count.shouldEqual(1)
        d4.elementByBirthDot[VersionDot(self.replicaA, V(1))].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted
        d4.elementByBirthDot[VersionDot(self.replicaA, V(3))].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted
        d4.elements.shouldEqual([5])

        aContainer.resetDelta()
        aContainer.delta.shouldBeNil()

        // `resetDelta` doesn't affect container's elementByBirthDot or versionContext
        aContainer.add(6)
        aContainer.elements.shouldEqual([5, 6])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 5, (A,4): 6], vv=[(A,4)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(4) // The container's vv should be incremented (3 -> 4)
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // No dot since we manipulate vv directly and not adding to gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(4))]!.shouldEqual(6) // Verify birth dot
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4)]
        guard let d5 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d5.versionContext.vv.isEmpty.shouldBeTrue() // New dot is non-contiguous (vv version is 0, new dot's version is 4) so `compact` doesn't add to vv
        d5.versionContext.gaps.count.shouldEqual(1) // Dot was added to gaps and `compact` can't merge it to vv
        d5.versionContext.gaps.contains(VersionDot(self.replicaA, 4)).shouldBeTrue()
        d5.elementByBirthDot.count.shouldEqual(1)
        d5.elementByBirthDot[VersionDot(self.replicaA, V(4))]!.shouldEqual(6) // Delta should also have the dot
        d5.elements.shouldEqual([6])

        aContainer.remove(5)
        aContainer.elements.shouldEqual([6])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,4): 6], vv=[(A,4)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(4) // `remove` doesn't change vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Removed dots are added to delta, not container's versionContext.gaps
        aContainer.elementByBirthDot.count.shouldEqual(1) // (A,2) removed; 2 - 1 = 1
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4), (A,2)]
        guard let d6 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d6.versionContext.vv.isEmpty.shouldBeTrue() // (A,2) non-contiguous so `compact` doesn't add to vv
        d6.versionContext.gaps.count.shouldEqual(2) // Dot was added to gaps and `compact` can't merge it to vv
        d6.versionContext.gaps.contains(VersionDot(self.replicaA, 2)).shouldBeTrue()
        d6.elementByBirthDot.count.shouldEqual(1)
        d6.elementByBirthDot[VersionDot(self.replicaA, V(2))].shouldBeNil() // Dot not in delta.elementByBirthDot indicates element is deleted
        d6.elements.shouldEqual([6])
    }

    func test_VersionedContainer_removeAll_shouldAddAllBirthDotsToDeltaVersionContext() throws {
        let versionContext = CRDT.VersionContext(vv: VersionVector([(self.replicaA, V(3)), (self.replicaB, V(1))]), gaps: [VersionDot(self.replicaB, V(5))])
        var aContainer = IntContainer(replicaId: replicaA, versionContext: versionContext, elementByBirthDot: [VersionDot(replicaA, V(2)): 4])

        // container: elementByBirthDot=[(A,2): 4], vv=[(A,3), (B,1)], gaps=[(B,5)]
        aContainer.elements.shouldEqual([4])
        aContainer.count.shouldEqual(1)
        aContainer.isEmpty.shouldBeFalse()
        aContainer.versionContext.vv[self.replicaA].shouldEqual(3)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(1)
        aContainer.versionContext.gaps.count.shouldEqual(1) // (B,5)
        aContainer.elementByBirthDot.count.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))].shouldEqual(4)
        aContainer.delta.shouldBeNil()

        aContainer.add(6)
        aContainer.elements.shouldEqual([4, 6])
        aContainer.count.shouldEqual(2)
        aContainer.isEmpty.shouldBeFalse()
        // container: elementByBirthDot=[(A,2): 4, (A,4): 6], vv=[(A,4), (B,1)], gaps=[(B,5)]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(4) // The container's vv should be incremented (3 -> 4)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(1) // Another replica's version untouched
        aContainer.versionContext.gaps.count.shouldEqual(1) // (B,5)
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(4))]!.shouldEqual(6) // Verify birth dot
        // delta: elementByBirthDot=[(A,4): 6], vv=[], gaps=[(A,4)]
        guard let d1 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d1.versionContext.vv.isEmpty.shouldBeTrue() // New dot is non-contiguous (vv version is 0, new dot's version is 4) so `compact` doesn't add to vv
        d1.versionContext.gaps.count.shouldEqual(1) // Dot was added to gaps and `compact` can't merge it to vv
        d1.versionContext.gaps.contains(VersionDot(self.replicaA, 4)).shouldBeTrue()
        d1.elementByBirthDot.count.shouldEqual(1)
        d1.elementByBirthDot[VersionDot(self.replicaA, V(4))]!.shouldEqual(6) // Delta should also have the dot
        d1.elements.shouldEqual([6])

        // Remove all elements!
        aContainer.removeAll()

        // container: elementByBirthDot=[], vv=[(A,4), (B,1)], gaps=[(B,5)]
        aContainer.elements.isEmpty.shouldBeTrue() // Elements deleted
        aContainer.count.shouldEqual(0)
        aContainer.isEmpty.shouldBeTrue()
        aContainer.versionContext.vv[self.replicaA].shouldEqual(4) // `removeAll` doesn't change container vv
        aContainer.versionContext.vv[self.replicaB].shouldEqual(1) // Another replica's version untouched
        aContainer.versionContext.gaps.count.shouldEqual(1) // `removeAll` doesn't change container gaps
        aContainer.elementByBirthDot.isEmpty.shouldBeTrue()
        // delta: elementByBirthDot=[], vv=[], gaps=[(A,4), (A,2)]
        guard let d2 = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }
        d2.versionContext.vv.isEmpty.shouldBeTrue() // `removeAll` doesn't change delta vv
        d2.versionContext.gaps.count.shouldEqual(2)
        d2.versionContext.gaps.contains(VersionDot(self.replicaA, 4)).shouldBeTrue()
        d2.versionContext.gaps.contains(VersionDot(self.replicaA, 2)).shouldBeTrue() // (A,2) was added to delta gaps
        d2.elementByBirthDot.isEmpty.shouldBeTrue() // Dots not in delta.elementByBirthDot indicates elements are deleted
        d2.elements.isEmpty.shouldBeTrue()
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
        aContainer.versionContext.vv[self.replicaA].shouldEqual(2)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))]!.shouldEqual(3)
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(1))]!.shouldEqual(3) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(2))]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
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
        aContainer.versionContext.vv[self.replicaA].shouldEqual(2)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))].shouldBeNil() // (A,2): 3 deleted in B and B's version context dominates A's, so A deleted it
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(1))].shouldBeNil() // (B,1): 3 deleted in B; A didn't see this
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(2))]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
    }

    func test_VersionedContainer_merge_twoReplicasFormCompleteHistory() throws {
        let aVersionContext = CRDT.VersionContext(vv: VersionVector([(self.replicaA, V(3)), (self.replicaB, V(1)), (self.replicaC, V(1))]), gaps: [VersionDot(self.replicaC, V(4)), VersionDot(self.replicaC, V(5))])
        var aContainer = IntContainer(replicaId: replicaA, versionContext: aVersionContext, elementByBirthDot: [VersionDot(replicaA, V(2)): 4, VersionDot(replicaC, V(4)): 0, VersionDot(replicaC, V(5)): 3])

        let bVersionContext = CRDT.VersionContext(vv: VersionVector([(self.replicaA, V(3)), (self.replicaB, V(1))]), gaps: [VersionDot(self.replicaC, V(2)), VersionDot(self.replicaC, V(3))])
        let bContainer = IntContainer(replicaId: replicaB, versionContext: bVersionContext, elementByBirthDot: [VersionDot(replicaA, V(2)): 4, VersionDot(replicaC, V(3)): 7])

        // `merge` mutates aContainer
        aContainer.merge(other: bContainer)
        aContainer.elements.shouldEqual([4, 7, 0, 3])
        // aContainer: elementByBirthDot=[(A,2): 4, (C,3): 7, (C,4): 0, (C,5): 3], vv=[(A,3), (B,1), (C,5)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(3)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(1)
        aContainer.versionContext.vv[self.replicaC].shouldEqual(5) // (C,2) and (C,3) from B filled the gaps and `compact` merged (C,4) and (C,5) to vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // ^^
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))]!.shouldEqual(4)
        aContainer.elementByBirthDot[VersionDot(self.replicaC, V(3))]!.shouldEqual(7)
        aContainer.elementByBirthDot[VersionDot(self.replicaC, V(4))]!.shouldEqual(0)
        aContainer.elementByBirthDot[VersionDot(self.replicaC, V(5))]!.shouldEqual(3)
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
        guard let bDelta = bContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(bContainer)")
        }

        // `mergeDelta` mutates aContainer
        aContainer.mergeDelta(bDelta)
        aContainer.elements.shouldEqual([1, 3, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(2)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(4)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))]!.shouldEqual(3)
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(1))]!.shouldEqual(3) // From B; A didn't have this dot and A's version context doesn't dominate B's
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(2))]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
    }

    func test_VersionedContainer_mergeDelta_replicaBHasRemovalsThatReplicaAHasNotSeen_replicaAShouldDelete() throws {
        var aContainer = IntContainer(replicaId: replicaA)
        var bContainer = IntContainer(replicaId: replicaB)

        aContainer.add(1)
        aContainer.add(3)
        // aContainer: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]; delta: elementByBirthDot=[(A,1): 1, (A,2): 3], vv=[(A,2)], gaps=[]
        guard let aDelta = aContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(aContainer)")
        }

        bContainer.add(3)
        // bContainer: elementByBirthDot=[(B,1): 3], vv=[(B,1)], gaps=[]

        // Merge aContainer.delta into bContainer so that the latter's version context dominates
        bContainer.mergeDelta(aDelta)
        // bContainer: elementByBirthDot=[(A,1): 1, (A,2): 3, (B,1): 3], vv=[(A,2), (B,1)], gaps=[]

        bContainer.remove(3)
        // bContainer: elementByBirthDot=[(A,1): 1], vv=[(A,2), (B,1)], gaps=[]; delta: elementByBirthDot=[], vv=[(B,1)], gaps=[(A,2)]
        bContainer.add(4)
        // bContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]; delta: elementByBirthDot=[(B,2): 4], vv=[(B,2)], gaps=[(A,2)]
        guard let bDelta = bContainer.delta else {
            throw shouldNotHappen("Expected delta to be non nil, got \(bContainer)")
        }

        // `mergeDelta` mutates aContainer
        aContainer.mergeDelta(bDelta)
        aContainer.elements.shouldEqual([1, 4])
        // aContainer: elementByBirthDot=[(A,1): 1, (B,2): 4], vv=[(A,2), (B,2)], gaps=[]
        aContainer.versionContext.vv[self.replicaA].shouldEqual(2)
        aContainer.versionContext.vv[self.replicaB].shouldEqual(2) // From B vv
        aContainer.versionContext.gaps.isEmpty.shouldBeTrue() // Both A and B have empty gaps
        aContainer.elementByBirthDot.count.shouldEqual(2)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(1))]!.shouldEqual(1)
        aContainer.elementByBirthDot[VersionDot(self.replicaA, V(2))].shouldBeNil() // (A,2): 3 deleted in B and B's version context dominates A's, so A deleted it
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(1))].shouldBeNil() // (B,1): 3 deleted in B; A didn't see this
        aContainer.elementByBirthDot[VersionDot(self.replicaB, V(2))]!.shouldEqual(4) // From B; A didn't have this dot and A's version context doesn't dominate B's
    }
}
