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
    let _nodeA = Node(systemName: "nodeA", host: "1.1.1.1", port: 7337)
    let _nodeB = Node(systemName: "nodeB", host: "2.2.2.2", port: 8228)
    let _nodeC = Node(systemName: "nodeC", host: "3.3.3.3", port: 9119)

    var allNodes: [UniqueNode] {
        [self.nodeA, self.nodeB, self.nodeC]
    }

    var stateA: ClusterShellState!
    var stateB: ClusterShellState!
    var stateC: ClusterShellState!

    var nodeA: UniqueNode {
        self.stateA.localNode
    }

    var nodeB: UniqueNode {
        self.stateB.localNode
    }

    var nodeC: UniqueNode {
        self.stateC.localNode
    }

    override func setUp() {
        self.stateA = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._nodeA
        }
        self.stateB = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._nodeB
        }
        self.stateC = ClusterShellState.makeTestMock(side: .server) { settings in
            settings.node = self._nodeC
        }

        _ = self.stateA.membership.join(self.nodeA)
        _ = self.stateA.membership.join(self.nodeB)
        _ = self.stateA.membership.join(self.nodeC)

        _ = self.stateB.membership.join(self.nodeA)
        _ = self.stateB.membership.join(self.nodeB)
        _ = self.stateB.membership.join(self.nodeC)

        _ = self.stateC.membership.join(self.nodeA)
        _ = self.stateC.membership.join(self.nodeB)
        _ = self.stateC.membership.join(self.nodeC)
        _ = self.stateA.latestGossip.mergeForward(incoming: self.stateB.latestGossip)

        _ = self.stateA.latestGossip.mergeForward(incoming: self.stateC.latestGossip)

        _ = self.stateB.latestGossip.mergeForward(incoming: self.stateA.latestGossip)
        _ = self.stateC.latestGossip.mergeForward(incoming: self.stateA.latestGossip)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Moving members to .removed

    func test_leaderActions_removeDownMembers_ifKnownAsDownToAllMembers() {
        // make A the leader
        let makeFirstTheLeader = Cluster.LeadershipChange(oldLeader: nil, newLeader: self.stateA.membership.member(self.nodeA.node)!)!
        _ = self.stateA.applyClusterEvent(.leadershipChange(makeFirstTheLeader))

        // time to mark B as .down
        _ = self.stateA.membership.mark(self.nodeB, as: .down) // only F knows that S is .down

        // ensure some nodes are up, so they participate in the convergence check
        _ = self.stateA.membership.mark(self.nodeA, as: .up)
        _ = self.stateA.membership.mark(self.nodeC, as: .up)

        // not yet converged, the first/third members need to chat some more, to ensure first knows that third knows that second is down
        self.stateA.latestGossip.converged().shouldBeFalse()
        let moveMembersUp = self.stateA.collectLeaderActions()
        moveMembersUp.count.shouldEqual(0)

        // we tell others about the latest gossip, that B is down
        // second does not get the information, let's assume we cannot communicate with it
        self.gossip(from: self.stateA, to: &self.stateC)

        // first and second now know that second is down
        self.stateA.membership.uniqueMember(self.nodeB)!.status.shouldEqual(.down)
        self.stateC.membership.uniqueMember(self.nodeB)!.status.shouldEqual(.down)

        // we gossiped to C, and it knows, but we don't know yet if it knows (if it has received the information)
        self.stateA.latestGossip.converged().shouldBeFalse()

        // after a gossip back...
        self.gossip(from: self.stateC, to: &self.stateA)

        // now first knows that all other up/leaving members also know about second being .down
        self.stateA.latestGossip.converged().shouldBeTrue()
        self.stateC.latestGossip.converged().shouldBeTrue() // also true, but not needed for the leader to make the decision

        let hopefullyRemovalActions = self.stateA.collectLeaderActions()
        hopefullyRemovalActions.count.shouldEqual(1)
        guard case .some(.removeMember(let member)) = hopefullyRemovalActions.first else {
            XCTFail("Expected a member removal action, but did not get one, actions: \(hopefullyRemovalActions)")
            return
        }
        member.status.isDown.shouldBeTrue()
        member.uniqueNode.shouldEqual(self.nodeB)

        // interpret leader actions would interpret it by removing the member now and tombstone-ing it,
        // see `interpretLeaderActions`
        _ = self.stateA.membership.removeCompletely(self.nodeB)
        self.stateA.latestGossip.membership.uniqueMember(self.nodeB).shouldBeNil()

        // once we (leader) have performed removal and talk to others, they should also remove and prune seen tables
        //
        // once a node is removed, it should not be seen in gossip seen tables anymore
        _ = self.gossip(from: self.stateA, to: &self.stateC)
    }

    func test_leaderActions_removeDownMembers_dontRemoveIfDownNotKnownToAllMembersYet() {
        // A is .down, but
        _ = self.stateB._latestGossip = .parse(
            """
            A.down B.up C.up [leader:B]
            A: A:7 B:2
            B: A:7 B:10 C:6
            C: A:7 B:5 C:6
            """, owner: self.nodeB, nodes: self.allNodes
        )

        self.stateB.latestGossip.converged().shouldBeFalse()
        let moveMembersUp = self.stateA.collectLeaderActions()
        moveMembersUp.count.shouldEqual(0)
    }

    @discardableResult
    private func gossip(from: ClusterShellState, to: inout ClusterShellState) -> Cluster.MembershipGossip.MergeDirective {
        to.latestGossip.mergeForward(incoming: from.latestGossip)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Moving members .up

    // TODO: same style of tests for upNumbers and moving members up
}
