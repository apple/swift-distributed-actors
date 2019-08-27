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

final class VersionVectorTests: XCTestCase {
    private typealias VV = VersionVector<String>

    private let replicaA = "A"
    private let replicaB = "B"
    private let replicaC = "C"

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: VersionVector tests

    func test_VersionVector_init_default_canModify() throws {
        var vv = VV()
        vv.isEmpty.shouldBeTrue()

        // Add "A"
        vv.increment(at: self.replicaA).shouldEqual(1)
        vv[replicaA].shouldEqual(1) // New replica gets added with version 1

        // Increment "A"
        vv.increment(at: self.replicaA).shouldEqual(2)
        vv[replicaA].shouldEqual(2) // 1 + 1

        // Add "B"
        vv.increment(at: self.replicaB).shouldEqual(1)
        vv[replicaA].shouldEqual(2) // No change
        vv[replicaB].shouldEqual(1) // New replica gets added with version 1
    }

    func test_VersionVector_init_fromVersionVector_canModify() throws {
        let sourceVV = VV([(replicaA, 1), (replicaB, 2)])
        var vv = VV(sourceVV)
        vv.isNotEmpty.shouldBeTrue()

        vv[replicaA].shouldEqual(1)
        vv[replicaB].shouldEqual(2)
        vv[replicaC].shouldEqual(0) // default

        // Increment "B"
        vv.increment(at: self.replicaB).shouldEqual(3)
        vv[replicaA].shouldEqual(1) // No change
        vv[replicaB].shouldEqual(3) // 2 + 1

        // Add "C"
        vv.increment(at: self.replicaC).shouldEqual(1)
        vv[replicaC].shouldEqual(1) // New replica gets added with version 1
    }

    func test_VersionVector_init_fromArrayOfReplicaVersionTuples_canModify() throws {
        var vv = VV([(replicaA, 1), (replicaB, 2)])
        vv.isNotEmpty.shouldBeTrue()

        vv[replicaA].shouldEqual(1)
        vv[replicaB].shouldEqual(2)
        vv[replicaC].shouldEqual(0) // default

        // Increment "B"
        vv.increment(at: self.replicaB).shouldEqual(3)
        vv[replicaA].shouldEqual(1) // No change
        vv[replicaB].shouldEqual(3) // 2 + 1

        // Add "C"
        vv.increment(at: self.replicaC).shouldEqual(1)
        vv[replicaC].shouldEqual(1) // New replica gets added with version 1
    }

    func test_VersionVector_merge_shouldMutate() throws {
        var vv1 = VV([(replicaA, 2), (replicaB, 3)])
        let vv2 = VV([(replicaA, 1), (replicaB, 4), (replicaC, 5)])

        // Mutates vv1
        vv1.merge(other: vv2)

        vv1[replicaA].shouldEqual(2) // 2 (vv1) > 1 (vv2)
        vv1[replicaB].shouldEqual(4) // 4 (vv2) > 3 (vv1)
        vv1[replicaC].shouldEqual(5) // From vv2

        // vv2 should remain the same
        vv2[replicaA].shouldEqual(1)
        vv2[replicaB].shouldEqual(4)
        vv2[replicaC].shouldEqual(5)
    }

    func test_VersionVector_contains() throws {
        let emptyVV = VV()
        emptyVV.contains(self.replicaA, 0).shouldBeTrue() // This is no version basically; always included
        emptyVV.contains(self.replicaA, 1).shouldBeFalse()

        let vv = VV([(replicaA, 2), (replicaB, 3)])
        vv.contains(self.replicaA, 1).shouldBeTrue() // 2 ≥ 1
        vv.contains(self.replicaA, 2).shouldBeTrue() // 2 ≥ 2
        vv.contains(self.replicaA, 3).shouldBeFalse() // 2 ≱ 3
        vv.contains(self.replicaB, 3).shouldBeTrue() // 3 ≥ 3
        vv.contains(self.replicaB, 4).shouldBeFalse() // 3 ≱ 4
        vv.contains(self.replicaC, 2).shouldBeFalse() // "C" not in vv
    }

    func test_VersionVector_comparisonOperators() throws {
        // Two empty version vectors should be considered equal instead of less than
        (VV() < VV()).shouldBeFalse()
        // Empty version vector is always less than non-empty
        (VV() < VV([(replicaA, 2)])).shouldBeTrue()
        // Every entry in lhs is <= rhs, and at least one is strictly less than
        (VV([(replicaA, 1), (replicaB, 2)]) < VV([(replicaA, 2), (replicaB, 3)])).shouldBeTrue()
        // Not every entry in lhs is <= rhs
        (VV([(replicaA, 1), (replicaB, 3)]) < VV([(replicaA, 2), (replicaB, 2)])).shouldBeFalse()
        // At least one entry in lhs must be strictly less than
        (VV([(replicaA, 1), (replicaB, 2)]) < VV([(replicaA, 2), (replicaB, 2)])).shouldBeFalse()

        // Two empty version vectors should be considered equal instead of greater than
        (VV() > VV()).shouldBeFalse()
        // Non-empty version vector is always greater than empty
        (VV([(replicaA, 2)]) > VV()).shouldBeTrue()
        // Every entry in lhs is >= rhs, and at least one is strictly greater than
        (VV([(replicaA, 2), (replicaB, 3)]) > VV([(replicaA, 1), (replicaB, 2)])).shouldBeTrue()
        // Not every entry in lhs is >= rhs
        (VV([(replicaA, 2), (replicaB, 2)]) > VV([(replicaA, 1), (replicaB, 3)])).shouldBeFalse()
        // At least one entry in lhs must be strictly greater than
        (VV([(replicaA, 2), (replicaB, 2)]) > VV([(replicaA, 1), (replicaB, 2)])).shouldBeFalse()

        // Two empty version vectors are considered equal
        (VV() == VV()).shouldBeTrue()
        // Two version vectors should be considered equal if elements are equal
        (VV([(replicaA, 2), (replicaB, 1)]) == VV([(replicaB, 1), (replicaA, 2)])).shouldBeTrue()
        (VV() == VV([(replicaA, 2)])).shouldBeFalse()
        (VV([(replicaA, 2), (replicaB, 3)]) == VV([(replicaB, 1), (replicaA, 2)])).shouldBeFalse()

        // x = [A:1, B:4, C:6], y = [A:2, B:7, C:2]
        // x ≮ y, y ≮ x, x != y
        let vvX = VV([(replicaA, 1), (replicaB, 4), (replicaC, 6)])
        let vvY = VV([(replicaA, 2), (replicaB, 7), (replicaC, 2)])
        (vvX < vvY).shouldBeFalse()
        (vvY < vvX).shouldBeFalse()
        (vvX > vvY).shouldBeFalse()
        (vvY > vvX).shouldBeFalse()
        (vvX == vvY).shouldBeFalse()
    }

    func test_VersionVector_compareTo() throws {
        guard case .happenedBefore = VV().compareTo(that: VV([(replicaA, 2)])) else {
            throw shouldNotHappen("An empty version vector is always before a non-empty one")
        }
        guard case .happenedBefore = VV([(replicaA, 1), (replicaB, 2)]).compareTo(that: VV([(replicaA, 2), (replicaB, 3)])) else {
            throw shouldNotHappen("Should be .happenedBefore relation since all entries in LHS are strictly less than RHS")
        }

        guard case .happenedAfter = VV([(replicaA, 2)]).compareTo(that: VV()) else {
            throw shouldNotHappen("A non-empty version vector is always after an empty one")
        }
        guard case .happenedAfter = VV([(replicaA, 2), (replicaB, 3)]).compareTo(that: VV([(replicaA, 1), (replicaB, 2)])) else {
            throw shouldNotHappen("Should be .happenedAfter relation since all entries in LHS are strictly greater than RHS")
        }

        guard case .same = VV().compareTo(that: VV()) else {
            throw shouldNotHappen("Two empty version vectors should be considered the same")
        }
        guard case .same = VV([(replicaA, 2), (replicaB, 1)]).compareTo(that: VV([(replicaB, 1), (replicaA, 2)])) else {
            throw shouldNotHappen("Two version vectors should be considered the same if elements are equal")
        }

        guard case .concurrent = VV([(replicaA, 1), (replicaB, 4), (replicaC, 6)]).compareTo(that: VV([(replicaA, 2), (replicaB, 7), (replicaC, 2)])) else {
            throw shouldNotHappen("Must be .concurrent relation if the two version vectors are not ordered or the same")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Dot tests

    func test_Dot_sort_shouldBeByReplicaThenByVersion() throws {
        let dot1 = Dot(replicaB, 2)
        let dot2 = Dot(replicaA, 3)
        let dot3 = Dot(replicaB, 1)
        let dot4 = Dot(replicaC, 5)
        let dots: Set<Dot> = [dot1, dot2, dot3, dot4]

        let sortedDots = dots.sorted()
        sortedDots.shouldEqual([dot2, dot3, dot1, dot4])
    }
}
