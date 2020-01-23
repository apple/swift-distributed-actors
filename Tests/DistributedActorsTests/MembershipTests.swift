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
    let memberA = Cluster.Member(node: UniqueNode(node: Node(systemName: "nodeA", host: "1.1.1.1", port: 1111), nid: .random()), status: .up)
    var nodeA: UniqueNode { self.memberA.node }

    let memberB = Cluster.Member(node: UniqueNode(node: Node(systemName: "nodeB", host: "2.2.2.2", port: 2222), nid: .random()), status: .up)
    var nodeB: UniqueNode { self.memberB.node }

    let memberC = Cluster.Member(node: UniqueNode(node: Node(systemName: "nodeC", host: "3.3.3.3", port: 3333), nid: .random()), status: .up)
    var nodeC: UniqueNode { self.memberC.node }

    let memberD = Cluster.Member(node: UniqueNode(node: Node(systemName: "nodeD", host: "4.4.4.4", port: 4444), nid: .random()), status: .up)
    var nodeD: UniqueNode { self.memberD.node }

    lazy var allNodes = [
        nodeA, nodeB, nodeC,
    ]

    lazy var initialMembership: Cluster.Membership = [
        memberA, memberB, memberC,
    ]
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: status ordering

    func test_status_ordering() {
        Cluster.MemberStatus.joining.shouldBeLessThanOrEqual(.joining)
        Cluster.MemberStatus.joining.shouldBeLessThan(.up)
        Cluster.MemberStatus.joining.shouldBeLessThan(.down)
        Cluster.MemberStatus.joining.shouldBeLessThan(.leaving)
        Cluster.MemberStatus.joining.shouldBeLessThan(.removed)

        Cluster.MemberStatus.up.shouldBeLessThanOrEqual(.up)
        Cluster.MemberStatus.up.shouldBeLessThan(.down)
        Cluster.MemberStatus.up.shouldBeLessThan(.leaving)
        Cluster.MemberStatus.up.shouldBeLessThan(.removed)

        Cluster.MemberStatus.leaving.shouldBeLessThanOrEqual(.leaving)
        Cluster.MemberStatus.leaving.shouldBeLessThan(.down)
        Cluster.MemberStatus.leaving.shouldBeLessThan(.removed)

        Cluster.MemberStatus.down.shouldBeLessThanOrEqual(.down)
        Cluster.MemberStatus.down.shouldBeLessThan(.removed)

        Cluster.MemberStatus.removed.shouldBeLessThanOrEqual(.removed)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: age ordering

    func test_age_ordering() {
        let ms = [
            Cluster.Member(node: memberA.node, status: .joining),
            Cluster.Member(node: memberA.node, status: .up, upNumber: 1),
            Cluster.Member(node: memberA.node, status: .down, upNumber: 4),
            Cluster.Member(node: memberA.node, status: .up, upNumber: 2),
        ]
        let ns = ms.sorted(by: Cluster.Member.ageOrdering).map { $0._upNumber }
        ns.shouldEqual([nil, 1, 2, 4])
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: equality

    // Implementation note:
    // See the Membership equality implementation for an in depth rationale why the equality works like this.

    func test_membership_equality() {
        let left: Cluster.Membership = [
            Cluster.Member(node: memberA.node, status: .up, upNumber: 1),
            Cluster.Member(node: memberB.node, status: .up, upNumber: 1),
            Cluster.Member(node: memberC.node, status: .up, upNumber: 1),
        ]
        let right: Cluster.Membership = [
            Cluster.Member(node: memberA.node, status: .up, upNumber: 1),
            Cluster.Member(node: memberB.node, status: .down, upNumber: 1),
            Cluster.Member(node: memberC.node, status: .up, upNumber: 1),
        ]

        left.shouldNotEqual(right)
        right.shouldNotEqual(left) // sanity check, since hand implemented equality
    }

    func test_member_equality() {
        // member identity is the underlying unique node, this status DOES NOT contribute to equality:
        var member = self.memberA
        member.status = .down
        member.shouldEqual(self.memberA)

        // addresses are different
        self.memberA.shouldNotEqual(self.memberB)

        // only the node id is different:
        let one = Cluster.Member(node: UniqueNode(node: Node(systemName: "firstA", host: "1.1.1.1", port: 1111), nid: .init(1)), status: .up)
        let two = Cluster.Member(node: UniqueNode(node: Node(systemName: "firstA", host: "1.1.1.1", port: 1111), nid: .init(12222)), status: .up)
        one.shouldNotEqual(two)

        // node names do not matter for equality:
        let three = Cluster.Member(node: UniqueNode(node: Node(systemName: "does", host: "1.1.1.1", port: 1111), nid: .init(1)), status: .up)
        let four = Cluster.Member(node: UniqueNode(node: Node(systemName: "not matter", host: "1.1.1.1", port: 1111), nid: .init(12222)), status: .up)
        three.shouldNotEqual(four)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Member lookups

    func test_member_replacement_shouldOfferChange() {
        var membership: Cluster.Membership = [memberA, memberB]
        let secondReplacement = Cluster.Member(
            node: UniqueNode(node: Node(systemName: self.nodeB.node.systemName, host: self.nodeB.node.host, port: self.nodeB.node.port), nid: .random()), status: .up
        )

        let change = membership.apply(Cluster.MembershipChange(member: secondReplacement))!
        change.isReplacement.shouldBeTrue()
        change.member.shouldEqual(secondReplacement)
        change.replacementDownPreviousNodeChange.shouldEqual(
            Cluster.MembershipChange(member: self.memberB, toStatus: .down)
        )

        membership.members(atLeast: .joining).count.shouldEqual(2)
        let memberNode = membership.uniqueMember(change.member.node)
        memberNode?.status.shouldEqual(Cluster.MemberStatus.up)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Applying changes

    func test_apply_LeadershipChange() throws {
        var membership = self.initialMembership
        membership.isLeader(self.memberA).shouldBeFalse()

        let change = try membership.applyLeadershipChange(to: self.memberA)
        change.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))
        membership.isLeader(self.memberA).shouldBeTrue()

        // applying "same change" no-op
        let noChange = try membership.applyLeadershipChange(to: self.memberA)
        noChange.shouldBeNil()

        // changing to no leader is ok
        let noLeaderChange = try membership.applyLeadershipChange(to: nil)
        noLeaderChange.shouldEqual(Cluster.LeadershipChange(oldLeader: self.memberA, newLeader: nil))

        do {
            _ = try membership.applyLeadershipChange(to: self.memberD) // not part of membership (!)
        } catch {
            "\(error)".shouldStartWith(prefix: "nonMemberLeaderSelected")
        }
    }

    func test_join_memberReplacement() {
        var membership = self.initialMembership

        let replacesFirstNode = UniqueNode(node: self.nodeA.node, nid: .random())

        let change = membership.join(replacesFirstNode)!

        change.isReplacement.shouldBeTrue()
        change.replaced.shouldEqual(self.memberA)
        change.replaced!.status.shouldEqual(self.memberA.status)
        change.node.shouldEqual(replacesFirstNode)
        change.toStatus.shouldEqual(.joining)
    }

    func test_apply_memberReplacement() throws {
        var membership = self.initialMembership

        let firstReplacement = Cluster.Member(node: UniqueNode(node: self.nodeA.node, nid: .init(111_111)), status: .up)

        try shouldNotThrow {
            guard let change = membership.apply(Cluster.MembershipChange(member: firstReplacement)) else {
                throw TestError("Expected a change, but didn't get one")
            }

            change.isReplacement.shouldBeTrue()
            change.replaced.shouldEqual(self.memberA)
            change.replaced!.status.shouldEqual(self.memberA.status)
            change.node.shouldEqual(firstReplacement.node)
            change.toStatus.shouldEqual(firstReplacement.status)
        }
    }

    func test_apply_memberRemoval() throws {
        var membership = self.initialMembership

        let removal = Cluster.Member(node: self.memberA.node, status: .removed)

        try shouldNotThrow {
            guard let change = membership.apply(Cluster.MembershipChange(member: removal)) else {
                throw TestError("Expected a change, but didn't get one")
            }

            change.isReplacement.shouldBeFalse()
            change.node.shouldEqual(removal.node)
            change.toStatus.shouldEqual(removal.status)

            membership.uniqueMember(self.memberA.node).shouldBeNil()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: member listing

    func test_members_listing() {
        self.initialMembership.members(atLeast: .joining).count.shouldEqual(3)
        self.initialMembership.members(atLeast: .up).count.shouldEqual(3)
        var changed = self.initialMembership
        _ = changed.mark(self.memberA.node, as: .down)
        changed.count(atLeast: .joining).shouldEqual(3)
        changed.count(atLeast: .up).shouldEqual(3)
        changed.count(atLeast: .leaving).shouldEqual(1)
        changed.count(atLeast: .down).shouldEqual(1)
        changed.count(atLeast: .removed).shouldEqual(0)
    }

    func test_members_listing_filteringByReachability() {
        var changed = self.initialMembership
        _ = changed.mark(self.memberA.node, as: .down)

        _ = changed.mark(self.memberA.node, reachability: .unreachable)
        _ = changed.mark(self.memberB.node, reachability: .unreachable)

        // exact status match

        changed.members(withStatus: .joining).count.shouldEqual(0)
        changed.members(withStatus: .up).count.shouldEqual(2)
        changed.members(withStatus: .down).count.shouldEqual(1)
        changed.members(withStatus: .leaving).count.shouldEqual(0)
        changed.members(withStatus: .removed).count.shouldEqual(0)

        changed.members(withStatus: .joining, reachability: .reachable).count.shouldEqual(0)
        changed.members(withStatus: .up, reachability: .reachable).count.shouldEqual(1)
        changed.members(withStatus: .down, reachability: .reachable).count.shouldEqual(0)
        changed.members(withStatus: .leaving, reachability: .reachable).count.shouldEqual(0)
        changed.members(withStatus: .removed, reachability: .reachable).count.shouldEqual(0)

        changed.members(withStatus: .joining, reachability: .unreachable).count.shouldEqual(0)
        changed.members(withStatus: .up, reachability: .unreachable).count.shouldEqual(1)
        changed.members(withStatus: .down, reachability: .unreachable).count.shouldEqual(1)
        changed.members(withStatus: .leaving, reachability: .unreachable).count.shouldEqual(0)
        changed.members(withStatus: .removed, reachability: .unreachable).count.shouldEqual(0)

        // at-least status match

        changed.members(atLeast: .joining, reachability: .reachable).count.shouldEqual(1)
        changed.members(atLeast: .up, reachability: .reachable).count.shouldEqual(1)
        changed.members(atLeast: .down, reachability: .reachable).count.shouldEqual(0)
        changed.members(atLeast: .leaving, reachability: .reachable).count.shouldEqual(0)
        changed.members(atLeast: .removed, reachability: .reachable).count.shouldEqual(0)

        changed.members(atLeast: .joining, reachability: .unreachable).count.shouldEqual(2)
        changed.members(atLeast: .up, reachability: .unreachable).count.shouldEqual(2)
        changed.members(atLeast: .leaving, reachability: .unreachable).count.shouldEqual(1)
        changed.members(atLeast: .down, reachability: .unreachable).count.shouldEqual(1)
        changed.members(atLeast: .removed, reachability: .unreachable).count.shouldEqual(0)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Marking

    func test_mark_shouldOnlyProceedForwardInStatuses() {
        let member = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .joining)

        var membership: Cluster.Membership = [member]

        // marking no-member -> no-op

        let noChange = membership.mark(member.node, as: .joining)
        noChange.shouldBeNil() // already joining

        let change1 = membership.mark(member.node, as: .up)
        change1.shouldNotBeNil()

        // testing string output as well as field on purpose
        // as if the fromStatus is not set we may infer it from other places; but in such change, we definitely want it in the `from`
        change1?.fromStatus.shouldEqual(.joining)
        change1?.toStatus.shouldEqual(.up)
        "\(change1!)".shouldContain("fromStatus: joining, toStatus: up)")

        membership.mark(member.node, as: .joining).shouldBeNil() // can't move "back"
        membership.mark(member.node, as: .up).shouldBeNil() // don't move to "same"

        let change2 = membership.mark(member.node, as: .down)
        change2.shouldNotBeNil()
        change2?.fromStatus.shouldEqual(.up)
        change2?.toStatus.shouldEqual(.down)
        "\(change2!)".shouldContain("fromStatus: up, toStatus: down)")

        membership.mark(member.node, as: .joining).shouldBeNil() // can't move "back"
        membership.mark(member.node, as: .up).shouldBeNil() // can't move "back", from down
    }

    func test_mark_shouldNotReturnChangeForMarkingAsSameStatus() {
        let member = self.memberA
        var membership: Cluster.Membership = [member]

        let noChange = membership.mark(member.node, as: member.status)
        noChange.shouldBeNil()
    }

    func test_mark_reachability() {
        let member = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .joining)

        var membership: Cluster.Membership = [member]
        membership.mark(member.node, reachability: .reachable).shouldEqual(nil) // no change

        let res1 = membership.mark(member.node, reachability: .unreachable)
        res1!.reachability.shouldEqual(.unreachable)

        membership.mark(member.node, reachability: .unreachable).shouldEqual(nil) // no change
        _ = membership.mark(member.node, reachability: .unreachable)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Replacements

    func test_join_overAnExistingMode_replacement() {
        var membership = self.initialMembership
        let secondReplacement = Cluster.Member(node: UniqueNode(node: self.nodeB.node, nid: .random()), status: .joining)
        let change = membership.join(secondReplacement.node)!
        change.isReplacement.shouldBeTrue()

        let members = membership.members(atLeast: .joining)
        var secondDown = self.memberB
        secondDown.status = .down

        members.count.shouldEqual(3)
        members.shouldContain(secondReplacement)
        members.shouldNotContain(self.memberB) // was replaced
    }

    func test_mark_replacement() throws {
        var membership: Cluster.Membership = [self.memberA]

        let firstReplacement = Cluster.Member(node: UniqueNode(node: self.nodeA.node, nid: .random()), status: .up)

        try shouldNotThrow {
            guard let change = membership.mark(firstReplacement.node, as: firstReplacement.status) else {
                throw TestError("Expected a change")
            }
            change.isReplacement.shouldBeTrue()
            change.replaced.shouldEqual(self.memberA)
            change.fromStatus.shouldEqual(.up)
            change.node.shouldEqual(firstReplacement.node)
            change.toStatus.shouldEqual(.up)
        }
    }

    func test_replacement_changeCreation() {
        var existing = self.memberA
        existing.status = .joining

        let replacement = Cluster.Member(node: UniqueNode(node: existing.node.node, nid: .random()), status: .up)

        let change = Cluster.MembershipChange(replaced: existing, by: replacement)
        change.isReplacement.shouldBeTrue()

        change.member.shouldEqual(replacement)
        change.node.shouldEqual(replacement.node)
        change.fromStatus.shouldEqual(existing.status)

        change.replaced!.status.shouldEqual(existing.status) // though we have the replaced member, it will have its own previous status
        change.replaced.shouldEqual(existing)

        change.isUp.shouldBeTrue() // up is the status of the replacement
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Moving members along their lifecycle

    func test_moveForward_MemberStatus() {
        var member = self.memberA
        member.status = .joining
        let joiningMember = member

        member.status = .up
        let upMember = member

        member.status = .leaving
        let leavingMember = member
        member.status = .down
        let downMember = member
        member.status = .removed

        member.status = .joining
        member.moveForward(to: .up).shouldEqual(Cluster.MembershipChange(member: joiningMember, toStatus: .up))
        member.status.shouldEqual(.up)
        member.moveForward(to: .joining).shouldEqual(nil) // no change, cannot move back

        member.moveForward(to: .up).shouldEqual(nil) // no change, cannot move to same status
        member.moveForward(to: .leaving).shouldEqual(Cluster.MembershipChange(member: upMember, toStatus: .leaving))
        member.status.shouldEqual(.leaving)

        member.moveForward(to: .joining).shouldEqual(nil) // no change, cannot move back
        member.moveForward(to: .up).shouldEqual(nil) // no change, cannot move back
        member.moveForward(to: .leaving).shouldEqual(nil) // no change, same
        member.moveForward(to: .down).shouldEqual(Cluster.MembershipChange(member: leavingMember, toStatus: .down))
        member.status.shouldEqual(.down)

        member.moveForward(to: .joining).shouldEqual(nil) // no change, cannot move back
        member.moveForward(to: .up).shouldEqual(nil) // no change, cannot move back
        member.moveForward(to: .leaving).shouldEqual(nil) // no change, cannot move back
        member.moveForward(to: .down).shouldEqual(nil) // no change, same
        member.moveForward(to: .removed).shouldEqual(Cluster.MembershipChange(member: downMember, toStatus: .removed))
        member.status.shouldEqual(.removed)

        member.status = .joining
        member.moveForward(to: .leaving).shouldEqual(Cluster.MembershipChange(member: joiningMember, toStatus: .leaving))
        member.status.shouldEqual(.leaving)

        member.status = .joining
        member.moveForward(to: .down).shouldEqual(Cluster.MembershipChange(member: joiningMember, toStatus: .down))
        member.status.shouldEqual(.down)

        member.status = .up
        member.moveForward(to: .removed).shouldEqual(Cluster.MembershipChange(member: upMember, toStatus: .removed))
        member.status.shouldEqual(.removed)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Diffing

    func test_membershipDiff_beEmpty_whenNothingChangedForIt() {
        let changed = self.initialMembership
        let diff = Cluster.Membership._diff(from: self.initialMembership, to: changed)
        diff.changes.count.shouldEqual(0)
    }

    func test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt() {
        let changed = self.initialMembership.marking(self.memberA.node, as: .leaving)

        let diff = Cluster.Membership._diff(from: self.initialMembership, to: changed)

        diff.changes.count.shouldEqual(1)
        let diffEntry = diff.changes.first!
        diffEntry.node.shouldEqual(self.memberA.node)
        diffEntry.fromStatus?.shouldEqual(.up)
        diffEntry.toStatus.shouldEqual(.leaving)
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberRemoved() {
        let changed = self.initialMembership.removingCompletely(self.memberA.node)

        let diff = Cluster.Membership._diff(from: self.initialMembership, to: changed)

        diff.changes.count.shouldEqual(1)
        let diffEntry = diff.changes.first!
        diffEntry.node.shouldEqual(self.memberA.node)
        diffEntry.fromStatus?.shouldEqual(.up)
        diffEntry.toStatus.shouldEqual(.removed)
    }

    func test_membershipDiff_shouldIncludeEntry_whenMemberAdded() {
        let changed = self.initialMembership.joining(self.memberD.node)

        let diff = Cluster.Membership._diff(from: self.initialMembership, to: changed)

        diff.changes.count.shouldEqual(1)
        let diffEntry = diff.changes.first!
        diffEntry.node.shouldEqual(self.memberD.node)
        diffEntry.fromStatus.shouldBeNil()
        diffEntry.toStatus.shouldEqual(.joining)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Merge Memberships

    func test_mergeForward_fromAhead_same() {
        var membership = self.initialMembership
        let ahead = self.initialMembership

        let changes = membership.mergeFrom(ahead: ahead)

        changes.count.shouldEqual(0)
        membership.shouldEqual(self.initialMembership)
    }

    func test_mergeForward_fromAhead_membership_withAdditionalMember() {
        var membership = self.initialMembership
        var ahead = membership
        _ = ahead.join(self.memberD.node)!

        let changes = membership.mergeFrom(ahead: ahead)

        changes.count.shouldEqual(1)
        membership.shouldEqual(self.initialMembership.joining(self.memberD.node))
    }

    func test_mergeForward_fromAhead_membership_withMemberNowDown() {
        var membership = Cluster.Membership.parse(
            """
            A.up B.up C.up [leader:C]
            """, nodes: self.allNodes
        )

        let ahead = Cluster.Membership.parse(
            """
            A.down B.up C.up 
            """, nodes: self.allNodes
        )

        let changes = membership.mergeFrom(ahead: ahead)

        changes.count.shouldEqual(1)
        var expected = membership
        _ = expected.mark(self.nodeA, as: .down)
        membership.shouldEqual(expected)
    }

    func test_mergeForward_fromAhead_membership_withNonMemberNowDown() {
        var membership = Cluster.Membership.parse(
            """
            A.up B.up
            """, nodes: self.allNodes
        )

        let ahead = Cluster.Membership.parse(
            """
            A.down B.up C.down 
            """, nodes: self.allNodes
        )

        let changes = membership.mergeFrom(ahead: ahead)

        changes.count.shouldEqual(1)
        var expected = membership
        _ = expected.mark(self.nodeA, as: .down)
        membership.shouldEqual(expected)
    }

    func test_mergeForward_fromAhead_membership_withExistingMemberNowRemoved() {
        var membership = self.initialMembership
        var ahead = membership
        _ = ahead.mark(self.memberA.node, as: .removed)

        let changes = membership.mergeFrom(ahead: ahead)

        changes.count.shouldEqual(1)
        changes.first!.toStatus.shouldEqual(.removed)
        membership.shouldEqual(self.initialMembership.removingCompletely(self.memberA.node))
    }

    func test_mergeForward_fromAhead_membership_withNonMemberNowRemoved() {
        var membership = self.initialMembership
        _ = membership.removeCompletely(self.memberA.node)

        var ahead = membership
        _ = ahead.mark(self.memberA.node, as: .removed)

        let changes = membership.mergeFrom(ahead: ahead)

        // it already was removed, thus a removal causes no change
        changes.count.shouldEqual(0)
        membership.shouldEqual(self.initialMembership.removingCompletely(self.memberA.node))
    }
}
