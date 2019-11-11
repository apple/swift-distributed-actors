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
import DistributedActorsTestTools
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
        let selection = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        let membership = self.initialMembership

        let change: LeadershipChange? = try selection.runElection(context: self.fakeContext, membership: membership).future.wait()
        change.shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))
    }

    func test_LowestReachableMember_notEnoughMembersToDecide() throws {
        let selection = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.remove(self.firstMember.node)

        // 2 members -> not enough to make decision anymore
        let change1: LeadershipChange? = try selection.runElection(context: self.fakeContext, membership: membership).future.wait()
        change1.shouldBeNil()

        _ = membership.join(self.newMember.node)

        // 3 members again, should work
        let change2: LeadershipChange? = try selection.runElection(context: self.fakeContext, membership: membership).future.wait()
        change2.shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }

    func test_LowestReachableMember_whenCurrentLeaderDown() throws {
        let selection = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try selection.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        _ = membership.mark(self.firstMember.node, as: .down)
        (try selection.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }

    func test_LowestReachableMember_whenCurrentLeaderUnreachable() throws {
        let selection = Leadership.LowestReachableMember(minimumNrOfMembers: 3)

        var membership = self.initialMembership
        _ = membership.join(self.newMember.node)

        (try selection.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.firstMember))

        _ = membership.mark(self.firstMember.node, reachability: .unreachable)
        (try selection.runElection(context: self.fakeContext, membership: membership).future.wait())
            .shouldEqual(LeadershipChange(oldLeader: nil, newLeader: self.secondMember))
    }
}
