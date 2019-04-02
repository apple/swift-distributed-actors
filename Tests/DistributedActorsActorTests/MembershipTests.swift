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

@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit
import XCTest

class MembershipTests: XCTestCase {

    let firstMember = Member(address: UniqueNodeAddress(address: NodeAddress(systemName: "System", host: "1.1.1.1", port: 7337), uid: .random()), status: .alive)
    let secondMember = Member(address: UniqueNodeAddress(address: NodeAddress(systemName: "System", host: "2.2.2.2", port: 8228), uid: .random()), status: .alive)
    let thirdMember = Member(address: UniqueNodeAddress(address: NodeAddress(systemName: "System", host: "3.3.3.3", port: 9119), uid: .random()), status: .alive)
    let newMember = Member(address: UniqueNodeAddress(address: NodeAddress(systemName: "System", host: "4.4.4.4", port: 1001), uid: .random()), status: .alive)

    lazy var initialMembership: Membership = [
        firstMember, secondMember, thirdMember
    ]

    func test_membershipDiff_beEmpty_whenNothingChangedForIt() {
        let changed = initialMembership
        let diff = Membership.diff(from: initialMembership, to: changed)
        diff.entries.count.shouldEqual(0)
    }

    func test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt() {
        let changed = initialMembership.marking(firstMember.address, as: .suspect)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.address.shouldEqual(firstMember.address)
        diffEntry.fromStatus?.shouldEqual(.alive)
        diffEntry.toStatus?.shouldEqual(.suspect)
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberRemoved() {
        let changed = initialMembership.removing(firstMember.address)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.address.shouldEqual(firstMember.address)
        diffEntry.fromStatus?.shouldEqual(.alive)
        diffEntry.toStatus.shouldBeNil()
    }
    func test_membershipDiff_shouldIncludeEntry_whenMemberAdded() {
        let changed = initialMembership.joining(newMember.address)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.address.shouldEqual(newMember.address)
        diffEntry.fromStatus.shouldBeNil()
        diffEntry.toStatus?.shouldEqual(.joining)
    }
}
