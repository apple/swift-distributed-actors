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

import DistributedActorsTestKit
import Logging
import NIO
import XCTest

@testable import DistributedCluster

final class LeadershipTests: XCTestCase {
    let memberA = Cluster.Member(
        node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "C", host: "1.1.1.1", port: 7337), nid: .random()),
        status: .up
    )
    let memberB = Cluster.Member(
        node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "B", host: "2.2.2.2", port: 8228), nid: .random()),
        status: .up
    )
    let memberC = Cluster.Member(
        node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "A", host: "3.3.3.3", port: 9119), nid: .random()),
        status: .up
    )
    let newMember = Cluster.Member(
        node: Cluster.Node(
            endpoint: Cluster.Endpoint(systemName: "System", host: "4.4.4.4", port: 1001),
            nid: .random()
        ),
        status: .up
    )

    let fakeContext = LeaderElectionContext(log: NoopLogger.make(), eventLoop: EmbeddedEventLoop())

    lazy var initialMembership: Cluster.Membership = [
        memberA, memberB, memberC,
    ]

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LowestAddressReachableMember

    func test_LowestAddressReachableMember_selectLeader() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        let membership = self.initialMembership

        let change: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))
    }

    func test_LowestAddressReachableMember_notEnoughMembersToDecide() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.removeCompletely(self.memberA.node)

        // 2 members -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change1.shouldBeNil()

        _ = membership.join(self.newMember.node)

        // 3 members again, should work
        let change2: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change2.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_notEnoughReachableMembersToDecide() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.mark(self.memberB.node, reachability: .unreachable)

        // 2 reachable members -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change1.shouldBeNil()

        _ = membership.join(self.newMember.node)

        // 3 reachable members again, 1 unreachable, should work
        let change2: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change2.shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))
    }

    func test_LowestAddressReachableMember_onlyUnreachableMembers_cantDecide() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.mark(self.memberA.node, reachability: .unreachable)
        _ = membership.mark(self.memberB.node, reachability: .unreachable)

        // 1 reachable member -> not enough to make decision anymore
        let change1: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        change1.shouldBeNil()
    }

    func test_LowestAddressReachableMember_notEnoughMembersToDecide_fromWithToWithoutLeader() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = try! membership.applyLeadershipChange(to: self.memberA)  // try! because `memberA` is a member

        var leader = membership.leader
        leader.shouldEqual(self.memberA)

        // leader is down:
        _ = membership.mark(self.memberA.node, as: .down)

        // 2 members -> not enough to make decision anymore
        // Since we go from a leader to without, there should be a change
        let change: Cluster.LeadershipChange? = try election.runElection(
            context: self.fakeContext,
            membership: membership
        ).future.wait()
        leader?.status = .down
        change.shouldEqual(Cluster.LeadershipChange(oldLeader: leader, newLeader: nil))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderDown() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.node, as: .down)
        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderDown_enoughMembers() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.node, as: .down)
        (try election.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberB))
    }

    func test_LowestAddressReachableMember_whenCurrentLeaderUnreachable_notEnoughMinMembers() throws {
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        _ = membership.mark(self.memberA.node, reachability: .unreachable)
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.memberA.asUnreachable)
    }

    func test_LowestAddressReachableMember_keepLeader_notEnoughMembers_DO_NOT_loseLeadershipIfBelowMinNrOfMembers()
        throws
    {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // - second leaves
        // ! no need to drop the leadership from the first node, it shall remain the leader;
        var election = Leadership.LowestReachableMember(minimumNrOfMembers: 3)  // loseLeadershipIfBelowMinNrOfMembers: false by default

        var membership: Cluster.Membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        // down third
        _ = membership.mark(self.memberC.node, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        // down second
        _ = membership.mark(self.memberB.node, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(self.memberA)
    }

    func test_LowestAddressReachableMember_keepLeader_notEnoughMembers_DO_loseLeadershipIfBelowMinNrOfMembers() throws {
        // - 3 nodes join
        // - first becomes leader
        // - third leaves
        // ! not enough members to sustain leader, it should not be trusted anymore
        var election = Leadership.LowestReachableMember(
            minimumNrOfMembers: 3,
            loseLeadershipIfBelowMinNrOfMembers: true
        )

        var membership: Cluster.Membership = self.initialMembership
        let applyToMembership: (Cluster.LeadershipChange?) throws -> (Cluster.LeadershipChange?) = { change in
            if let change = change {
                _ = try membership.applyLeadershipChange(to: change.newLeader)
            }
            return change
        }

        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: nil, newLeader: self.memberA))

        // down third
        _ = membership.mark(self.memberC.node, as: .down)
        // no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(Cluster.LeadershipChange(oldLeader: self.memberA, newLeader: nil))

        // down second
        _ = membership.mark(self.memberB.node, as: .down)
        // STILL no reason to remove the leadership from the first node
        try election.runElection(context: self.fakeContext, membership: membership).future.wait()
            .map(applyToMembership)
            .shouldEqual(nil)

        membership.leader.shouldEqual(nil)
    }
}
