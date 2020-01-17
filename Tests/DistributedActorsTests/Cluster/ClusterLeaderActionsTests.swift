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
import Foundation
import NIOSSL
import XCTest

// Unit tests of the actions, see `ClusterLeaderActionsClusteredTests` for integration tests
final class ClusterLeaderActionsTests: XCTestCase {
    let _firstNode = Node(systemName: "System", host: "1.1.1.1", port: 7337)
    let _secondNode = Node(systemName: "System", host: "2.2.2.2", port: 8228)
    let _thirdNode = Node(systemName: "System", host: "3.3.3.3", port: 9119)

    var first: ClusterShellState!
    var second: ClusterShellState!
    var third: ClusterShellState!

    var firstNode: UniqueNode {
        self.first.myselfNode
    }

    var secondNode: UniqueNode {
        self.second.myselfNode
    }

    var thirdNode: UniqueNode {
        self.third.myselfNode
    }

    override func setUp() {
        self.first = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._firstNode
        }
        self.second = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._secondNode
        }
        self.third = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._thirdNode
        }

        _ = self.first.membership.join(self.firstNode)
        _ = self.first.membership.join(self.secondNode)
        _ = self.first.membership.join(self.thirdNode)

        _ = self.second.membership.join(self.firstNode)
        _ = self.second.membership.join(self.secondNode)
        _ = self.second.membership.join(self.thirdNode)

        _ = self.third.membership.join(self.firstNode)
        _ = self.third.membership.join(self.secondNode)
        _ = self.third.membership.join(self.thirdNode)
        _ = self.first.latestGossip.mergeForward(incoming: self.second.latestGossip)

        _ = self.first.latestGossip.mergeForward(incoming: self.third.latestGossip)

        _ = self.second.latestGossip.mergeForward(incoming: self.first.latestGossip)
        _ = self.third.latestGossip.mergeForward(incoming: self.first.latestGossip)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Moving members to .removed

    func test_leaderActions_removeDownMembers_ifKnownAsDownToAllMembers() {
        // make F the leader
        let makeFirstTheLeader = Cluster.LeadershipChange(oldLeader: nil, newLeader: self.first.membership.firstMember(self.firstNode.node)!)!
        self.first.applyClusterEventAsChange(.leadershipChange(makeFirstTheLeader))

        // time to mark S as .down
        _ = self.first.membership.mark(self.secondNode, as: .down) // only F knows that S is .down

        // no removal action yet
        let moveMembersUp = self.first.collectLeaderActions()
        moveMembersUp.shouldContain(.moveMember(Cluster.MembershipChange(member: .init(node: self.firstNode, status: .joining), toStatus: .up)))
        moveMembersUp.shouldContain(.moveMember(Cluster.MembershipChange(member: .init(node: self.thirdNode, status: .joining), toStatus: .up)))
        moveMembersUp.count.shouldEqual(2) // S is down, but F and T shall move to .up

        // apply the changes manually (as we don't run the actual real shell)
        _ = self.first.membership.mark(self.firstNode, as: .up)
        _ = self.first.membership.mark(self.thirdNode, as: .up)

        // we tell others about the latest gossip, that S is down
        // second does not get the information, let's assume we cannot communicate with it
        self.gossip(from: self.first, to: &self.third)

        // all non-down nodes now know that S is .down
        self.first.membership.uniqueMember(self.secondNode)!.status.shouldEqual(.down)
        // assuming second is dead, do not gossip to it
        self.third.membership.uniqueMember(self.secondNode)!.status.shouldEqual(.down)

        let firstLeaderActionsNotYet = self.first.collectLeaderActions()
        firstLeaderActionsNotYet.shouldBeEmpty() // since we don't know if T has seen the [.down] yet

        // once T gossips to F, and now we know it has seen the .down information we told it about
        self.gossip(from: self.third, to: &self.first)

        let hopefullyRemovalActions = self.first.collectLeaderActions()
        hopefullyRemovalActions.shouldBeNotEmpty()
        guard case .some(.removeDownMember(let member)) = (hopefullyRemovalActions.first { "\($0)".starts(with: "remove") }) else {
            // TODO: more type-ish assertion
            XCTFail("Expected a member removal action, but did not get one, actions: \(hopefullyRemovalActions)")
            return
        }

        member.status.isDown.shouldBeTrue()
        member.node.shouldEqual(self.secondNode)
    }

    @discardableResult
    private func gossip(from: ClusterShellState, to: inout ClusterShellState) -> Cluster.Gossip.MergeDirective {
        to.latestGossip.mergeForward(incoming: from.latestGossip)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Moving members .up

    // TODO: same style of tests for upNumbers and moving members up
}
