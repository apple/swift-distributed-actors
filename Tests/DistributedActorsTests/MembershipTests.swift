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

final class MembershipTests: XCTestCase {
    let firstMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let secondMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)
    let thirdMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "3.3.3.3", port: 9119), nid: .random()), status: .up)
    let newMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .up)

    lazy var initialMembership: Membership = [
        firstMember, secondMember, thirdMember,
    ]

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: status ordering

    func test_status_ordering() {
        MemberStatus.joining.shouldBeLessThanOrEqual(.joining)
        MemberStatus.joining.shouldBeLessThan(.up)
        MemberStatus.joining.shouldBeLessThan(.down)
        MemberStatus.joining.shouldBeLessThan(.leaving)
        MemberStatus.joining.shouldBeLessThan(.removed)

        MemberStatus.up.shouldBeLessThanOrEqual(.up)
        MemberStatus.up.shouldBeLessThan(.down)
        MemberStatus.up.shouldBeLessThan(.leaving)
        MemberStatus.up.shouldBeLessThan(.removed)

        MemberStatus.down.shouldBeLessThanOrEqual(.down)
        MemberStatus.down.shouldBeLessThan(.leaving)
        MemberStatus.down.shouldBeLessThan(.removed)

        MemberStatus.leaving.shouldBeLessThanOrEqual(.leaving)
        MemberStatus.leaving.shouldBeLessThan(.removed)

        MemberStatus.removed.shouldBeLessThanOrEqual(.removed)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: member listing

    func test_members_listing() {
        self.initialMembership.members(atLeast: .joining).count.shouldEqual(0)
        self.initialMembership.members(atLeast: .up).count.shouldEqual(3)
        var changed = self.initialMembership
        _ = changed.mark(self.firstMember.node, as: .down)
        changed.members(atLeast: .up).count.shouldEqual(2)
        changed.members(atLeast: .down).count.shouldEqual(3)
        changed.members(atLeast: .leaving).count.shouldEqual(3)
        changed.members(atLeast: .removed).count.shouldEqual(3)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------

    // MARK: Marking

    func test_mark_shouldOnlyProceedForwardInStatuses() {
        let member = Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .joining)

        var membership: Membership = [member]

        membership.mark(member.node, as: .joining).shouldBeNil() // already joining

        let change1 = membership.mark(member.node, as: .up)
        change1.shouldNotBeNil()
        "\(change1!)".shouldContain("[joining] -> [     up]")

        membership.mark(member.node, as: .joining).shouldBeNil() // can't move "back"
        membership.mark(member.node, as: .up).shouldBeNil() // don't move to "same"

        let change2 = membership.mark(member.node, as: .down)
        change2.shouldNotBeNil()
        "\(change2!)".shouldContain("[     up] -> [   down]")

        membership.mark(member.node, as: .joining).shouldBeNil() // can't move "back"
        membership.mark(member.node, as: .up).shouldBeNil() // can't move "back", from down
    }

    func test_mark_reachability() {
        let member = Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .joining)

        var membership: Membership = [member]
        membership.mark(member.node, reachability: .reachable).shouldEqual(nil) // no change

        let res1 = membership.mark(member.node, reachability: .unreachable)
        res1!.reachability.shouldEqual(.unreachable)

        membership.mark(member.node, reachability: .unreachable).shouldEqual(nil) // no change
        let res2 = membership.mark(member.node, reachability: .unreachable)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: diff

    func test_membershipDiff_beEmpty_whenNothingChangedForIt() {
        let changed = self.initialMembership
        let diff = Membership.diff(from: self.initialMembership, to: changed)
        diff.entries.count.shouldEqual(0)
    }

    func test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt() {
        let changed = self.initialMembership.marking(self.firstMember.node, as: .leaving)

        let diff = Membership.diff(from: self.initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(self.firstMember.node)
        diffEntry.fromStatus?.shouldEqual(.up)
        diffEntry.toStatus?.shouldEqual(.leaving)
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberRemoved() {
        let changed = self.initialMembership.removing(self.firstMember.node)

        let diff = Membership.diff(from: self.initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(self.firstMember.node)
        diffEntry.fromStatus?.shouldEqual(.up)
        diffEntry.toStatus.shouldBeNil()
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberAdded() {
        let changed = self.initialMembership.joining(self.newMember.node)

        let diff = Membership.diff(from: self.initialMembership, to: changed)

        diff.entries.count.shouldEqual(1)
        let diffEntry = diff.entries.first!
        diffEntry.node.shouldEqual(self.newMember.node)
        diffEntry.fromStatus.shouldBeNil()
        diffEntry.toStatus?.shouldEqual(.joining)
    }
}
