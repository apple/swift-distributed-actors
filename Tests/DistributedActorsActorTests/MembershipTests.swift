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

final class MembershipTests: XCTestCase {

    let firstMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .alive)
    let secondMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .alive)
    let thirdMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "3.3.3.3", port: 9119), nid: .random()), status: .alive)
    let newMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .alive)

    lazy var initialMembership: Membership = [
        firstMember, secondMember, thirdMember
    ]

    func test_membershipDiff_beEmpty_whenNothingChangedForIt() {
        let changed = initialMembership
        let diff = Membership.diff(from: initialMembership, to: changed)
        diff.entries.count.shouldEqual(0)
    }

    func test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt() {
        let changed = initialMembership.marking(firstMember.node, as: .suspect)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(firstMember.node)
        diffEntry.fromStatus?.shouldEqual(.alive)
        diffEntry.toStatus?.shouldEqual(.suspect)
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberRemoved() {
        let changed = initialMembership.removing(firstMember.node)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(firstMember.node)
        diffEntry.fromStatus?.shouldEqual(.alive)
        diffEntry.toStatus.shouldBeNil()
    }
    func test_membershipDiff_shouldIncludeEntry_whenMemberAdded() {
        let changed = initialMembership.joining(newMember.node)

        let diff = Membership.diff(from: initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(newMember.node)
        diffEntry.fromStatus.shouldBeNil()
        diffEntry.toStatus?.shouldEqual(.joining)
    }
}
