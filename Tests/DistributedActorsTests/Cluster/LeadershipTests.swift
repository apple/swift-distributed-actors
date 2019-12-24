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
    let firstMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let secondMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)
    let thirdMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "3.3.3.3", port: 9119), nid: .random()), status: .up)
    let newMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "4.4.4.4", port: 1001), nid: .random()), status: .up)

    let fakeContext = LeaderElectionContext(log: Logger(label: "mock"), eventLoop: EmbeddedEventLoop())

    lazy var initialMembership: Membership = [
        firstMember, secondMember, thirdMember,
    ]

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LowestReachableMember

    func test_LowestReachableMember_selectLeader() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        let membership = self.initialMembership

        let change: LeadershipChange? = try election.runElection(context: self.fakeContext, membership: membership).future.wait()
        change.shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))
    }

    func test_LowestReachableMember_notEnoughMembersToDecide() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.remove(self.firstMember.node)

        // 2 members -> not enough to make decision anymore
        let change1: LeadershipChange? = try election.runElection(context: self.fakeContext, membership: membership).future.wait()
        change1.shouldBeNil()

        _ = membership.join(self.newMember.node)

        // 3 members again, should work
        let change2: LeadershipChange? = try election.runElection(context: self.fakeContext, membership: membership).future.wait()
        change2.shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }

    func test_LowestReachableMember_notEnoughMembersToDecide_fromWithToWithoutLeader() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = try! membership.applyLeadershipChange(to: self.firstMember) // try! because `firstMember` is a member

        let leader = membership.leader
        leader.shouldEqual(self.firstMember)

        // leader is down:
        _ = membership.mark(self.firstMember.node, as: .down)

        // 2 members -> not enough to make decision anymore
        // Since we go from a leader to without, there should be a change
        let change: LeadershipChange? = try election.runElection(context: self.fakeContext, membership: membership).future.wait()
        change.shouldEqual(LeadershipChange(oldLeader: leader, newLeader: nil))
    }

    func test_LowestReachableMember_whenCurrentLeaderDown() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        _ = membership.mark(self.firstMember.node, as: .down)
        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }

    func test_LowestReachableMember_whenCurrentLeaderUnreachable_enoughMembers() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        _ = membership.mark(self.firstMember.node, reachability: .unreachable)
        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }

    func test_LowestReachableMember_whenCurrentLeaderUnreachable_notEnoughMinMembers() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        let applyToMembership: (LeadershipChange?) throws -> (LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        _ = membership.mark(self.firstMember.node, reachability: .unreachable)
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.firstMember)
    }

    func test_LowestReachableMember_keepLeader_notEnoughMembers_DO_NOT_loseLeadershipIfBelowMinNrOfMembers() throws {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // - second leaves
        // ! no need to drop the leadership from the first node, it shall remain the leader;
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3) // loseLeadershipIfBelowMinNrOfMembers: false by default

        var membership: Membership = self.initialMembership
        let applyToMembership: (LeadershipChange?) throws -> (LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        // down third
        _ = membership.mark(self.thirdMember.node, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        // down second
        _ = membership.mark(self.secondMember.node, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.firstMember)
    }

    func test_LowestReachableMember_keepLeader_notEnoughMembers_DO_loseLeadershipIfBelowMinNrOfMembers() throws {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // ! not enough members to sustain leader, it should not be trusted anymore
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3, loseLeadershipIfBelowMinNrOfMembers: true)

        var membership: Membership = self.initialMembership
        let applyToMembership: (LeadershipChange?) throws -> (LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        // down third
        _ = membership.mark(self.thirdMember.node, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(LeadershipChange(oldLeader: self.firstMember, newLeader: nil))

        // down second
        _ = membership.mark(self.secondMember.node, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(nil)
    }
}
