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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Collect leader actions

extension ClusterShellState {
    /// If, and only if, the current node is a leader it performs a set of tasks, such as moving nodes to `.up` etc.
    func collectLeaderActions() -> [LeaderAction] {
        guard self.membership.isLeader(self.localNode) else {
            return [] // since we are not the leader, we perform no tasks
        }

        guard self.latestGossip.converged() else {
            return [] // leader actions are only performed when up nodes are converged
        }

        func collectMemberUpMoves() -> [LeaderAction] {
            let joiningMembers = self.membership.members(withStatus: .joining).sorted(by: Cluster.Member.ageOrdering)

            return joiningMembers.map { joiningMember in
                let change = Cluster.MembershipChange(member: joiningMember, toStatus: .up)
                return LeaderAction.moveMember(change)
            }
        }

        func collectDownMemberRemovals() -> [LeaderAction] {
            let toExitMembers = self.membership.members(withStatus: .down)

            return toExitMembers.map { member in
                LeaderAction.removeMember(alreadyDownMember: member)
            }
        }

        var leadershipActions: [LeaderAction] = []
        leadershipActions += collectMemberUpMoves()
        leadershipActions += collectDownMemberRemovals()

        return leadershipActions
    }

    enum LeaderAction: Equatable {
        case moveMember(Cluster.MembershipChange)
        case removeMember(alreadyDownMember: Cluster.Member)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Interpret leader actions in Shell

extension ClusterShell {
    func interpretLeaderActions(
        _ system: ActorSystem,
        _ previousState: ClusterShellState,
        _ leaderActions: [ClusterShellState.LeaderAction],
        file: String = #file, line: UInt = #line
    ) -> ClusterShellState {
        guard !leaderActions.isEmpty else {
            return previousState
        }

        var state = previousState
        state.log.trace(
            "Performing leader actions: \(leaderActions)",
            metadata: [
                "tag": "leader-action",
                "leader/actions": "\(leaderActions)",
                "gossip/converged": "\(state.latestGossip.converged())",
                "gossip/current": "\(state.latestGossip)",
                "leader/interpret/location": "\(file):\(line)",
            ]
        )

        for leaderAction in leaderActions {
            switch leaderAction {
            case .moveMember(let movingUp):
                self.interpretMoveMemberLeaderAction(&state, movingUp: movingUp)

            case .removeMember(let memberToRemove):
                self.interpretRemoveMemberLeaderAction(system, &state, memberToRemove: memberToRemove)
            }
        }

        previousState.log.trace(
            "Membership state after leader actions: \(state.membership)",
            metadata: [
                "tag": "leader-action",
                "leader/interpret/location": "\(file):\(line)",
                "gossip/current": "\(state.latestGossip)",
                "gossip/before": "\(previousState.latestGossip)",
            ]
        )

        system.cluster.updateMembershipSnapshot(state.membership)

        return state
    }

    func interpretMoveMemberLeaderAction(_ state: inout ClusterShellState, movingUp: Cluster.MembershipChange) {
        guard let change = state.membership.applyMembershipChange(movingUp) else {
            return
        }

        if let downReplacedNodeChange = change.replacementDownPreviousNodeChange {
            state.log.debug("Downing replaced member: \(change)", metadata: ["tag": "leader-action"])
            state.events.publish(.membershipChange(downReplacedNodeChange))
        }

        state.log.debug("Leader moved member: \(change)", metadata: ["tag": "leader-action"])
        state.events.publish(.membershipChange(change))
    }

    /// Removal also terminates (and tombstones) the association to the given node.
    func interpretRemoveMemberLeaderAction(_ system: ActorSystem, _ state: inout ClusterShellState, memberToRemove: Cluster.Member) {
        let previousGossip = state.latestGossip
        // !!! IMPORTANT !!!
        // We MUST perform the prune on the _latestGossip_, not the wrapper,
        // as otherwise the wrapper enforces "vector time moves forward"
        guard let removalChange = state._latestGossip.pruneMember(memberToRemove) else {
            return
        }
        state._latestGossip.incrementOwnerVersion()
        state.gossiperControl.update(payload: state._latestGossip)

        self.terminateAssociation(system, state: &state, memberToRemove.node)

        state.log.info(
            "Leader removed member: \(memberToRemove), all nodes are certain to have seen it as [.down] before",
            metadata: [
                "tag": "leader-action",
                "gossip/current": "\(state.latestGossip)",
                "gossip/before": "\(previousGossip)",
            ]
        )

        // TODO: will this "just work" as we removed from membership, so gossip will tell others...?
        // or do we need to push a round of gossip with .removed anyway?
        state.events.publish(.membershipChange(removalChange))
    }
}
