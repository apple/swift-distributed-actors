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
import Logging
import NIO
import XCTest

final class LeadershipTests: XCTestCase {
    let memberA = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let memberB = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)
    let memberC = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "3.3.3.3", port: 9119), nid: .random()), status: .up)
    let newMember = Cluster.Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .up)

    lazy var initialMembership: Cluster.Membership = [
        memberA, memberB, memberC,
    ]

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LowestAddressReachableMember

    func test_LowestAddressReachableMember_selectLeader() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        let membership = self.initialMembership

        let change: Cluster.LeadershipChange? = try await election.runElection(context: self.fakeContext, membership: membership)
        change.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))
    }

    func test_LowestAddressReachableMember_notEnoughMembersToDecide() throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.removeCompletely(self.memberA.uniqueNode)

        // 2 members -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        change1.shouldBeNil()

        _ = membership.join(self.newMember.uniqueNode)

        // 3 members again, should work
        let change2: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        change2.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_notEnoughReachableMembersToDecide() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.mark(self.memberB.uniqueNode, reachability: .unreachable)

        // 2 reachable members -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        change1.shouldBeNil()

        _ = membership.join(self.newMember.uniqueNode)

        // 3 reachable members again, 1 unreachable, should work
        let change2: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        change2.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))
    }

    func test_LowestAddressReachableMember_onlyUnreachableMembers_cantDecide() throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.mark(self.memberA.uniqueNode, reachability: .unreachable)
        _ = membership.mark(self.memberB.uniqueNode, reachability: .unreachable)

        // 1 reachable member -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        change1.shouldBeNil()
    }

    func test_LowestAddressReachableMember_notEnoughMembersToDecide_fromWithToWithoutLeader() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = try! membership.applyLeadershipChange(to: self.memberA) // try! because `memberA` is a member

        var leader = membership.leader
        leader.shouldEqual(self.memberA)

        // leader is down:
        _ = membership.mark(self.memberA.uniqueNode, as: .down)

        // 2 members -> not enough to make decision anymore
        // Since we go from a leader to without, there should be a change
        let change: Cluster.LeadershipChange? = try await election.runElection(membership: membership)
        leader?.status = .down
        change.shouldEqual(Cluster.LeadershipChange(oldLeader: leader, newLeader: nil))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderDown() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.uniqueNode)

        (try await election.runElection(membership: membership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.uniqueNode, as: .down)
        (try election.runElection(context: self.fakeContext, membership: membership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderDown_enoughMembers() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.uniqueNode)

        (try election.runElection(context: self.fakeContext, membership: membership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.uniqueNode, as: .down)
        (try election.runElection(context: self.fakeContext, membership: membership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderUnreachable_notEnoughMinMembers() async throws {
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.uniqueNode, reachability: .unreachable)
        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.memberA.asUnreachable)
    }

    func test_LowestAddressReachableMember_keepLeader_notEnoughMembers_DO_NOT_loseLeadershipIfBelowMinNrOfMembers() async throws {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // - second leaves
        // ! no need to drop the leadership from the first node, it shall remain the leader;
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3) // loseLeadershipIfBelowMinNrOfMembers: false by default

        var membership: Cluster.Membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        // down third
        _ = membership.mark(self.memberC.uniqueNode, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(nil)

        // down second
        _ = membership.mark(self.memberB.uniqueNode, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.memberA)
    }

    func test_LowestAddressReachableMember_keepLeader_notEnoughMembers_DO_loseLeadershipIfBelowMinNrOfMembers() async throws {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // ! not enough members to sustain leader, it should not be trusted anymore
        var election = ClusterLeadership.LowestReachableMember(minimumNrOfMembers: 3, loseLeadershipIfBelowMinNrOfMembers: true)

        var membership: Cluster.Membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        // down third
        _ = membership.mark(self.memberC.uniqueNode, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership)
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: self.memberA, newLeader: nil))

        // down second
        _ = membership.mark(self.memberB.uniqueNode, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(membership: membership)
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(nil)
    }
}
