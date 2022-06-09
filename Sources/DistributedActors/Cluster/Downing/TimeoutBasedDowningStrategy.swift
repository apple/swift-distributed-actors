//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// The `TimeoutBasedDowningStrategy` marks nodes that have been unreachable as `.down` after a configurable timeout.
///
/// Only the node that is currently the currently assigned leader can make the decision to mark another node as down.
/// Non-leading nodes will keep track of the nodes they would have marked down and do so in case they become leader.
/// If a node becomes reachable again before the timeout expires, it will not be considered for downing anymore.
public final class TimeoutBasedDowningStrategy: DowningStrategy {
    let settings: TimeoutBasedDowningStrategySettings
    let selfNode: UniqueNode

    var membership: Cluster.Membership

    var isLeader: Bool {
        self.membership.isLeader(self.selfNode)
    }

    // unreachable members will be marked down after the timeout expires
    var _unreachable: Set<Cluster.Member>

    // buffer for nodes that will be marked down, if this node becomes the leader
    var _markAsDown: Set<Cluster.Member>

    init(_ settings: TimeoutBasedDowningStrategySettings, selfNode: UniqueNode) {
        self.settings = settings
        self.selfNode = selfNode
        self._unreachable = []
        self._markAsDown = []
        self.membership = .empty
    }

    public func onClusterEvent(event: Cluster.Event) throws -> DowningStrategyDirective {
        switch event {
        case .snapshot(let snapshot):
            self.membership = snapshot
            return .none

        case .membershipChange(let change):
            guard let change = self.membership.applyMembershipChange(change) else {
                return .none
            }

            if change.isAtLeast(.down) {
                // it was marked as down by someone, we don't need to track it anymore
                _ = self._markAsDown.remove(change.member)
                _ = self._unreachable.remove(change.member)
                return .cancelTimer(key: self.timerKey(change.member))
            } else if let replaced = change.replaced {
                _ = self._markAsDown.remove(replaced)
                _ = self._unreachable.remove(replaced)
                return .markAsDown(members: [replaced])
            }

            return .none

        case .leadershipChange(let change):
            return try self.onLeaderChange(to: change.newLeader)

        case .reachabilityChange(let change):
            if change.toUnreachable {
                return self.onMemberUnreachable(change)
            } else {
                return self.onMemberReachable(change)
            }
        }
    }

    public func onTimeout(_ member: Cluster.Member) -> DowningStrategyDirective {
        guard let nodeToDown = self._unreachable.remove(member) else {
            return .none // perhaps we removed it already for other reasons (e.g. node replacement)
        }
        if self.isLeader {
            return .markAsDown(members: [nodeToDown])
        } else {
            self._markAsDown.insert(nodeToDown)
            return .none
        }
    }

    func onMemberUnreachable(_ change: Cluster.ReachabilityChange) -> DowningStrategyDirective {
        _ = self.membership.applyReachabilityChange(change)
        let member = change.member

        self._unreachable.insert(member)

        return .startTimer(key: self.timerKey(member), member: member, delay: self.settings.downUnreachableMembersAfter)
    }

    func onMemberReachable(_ change: Cluster.ReachabilityChange) -> DowningStrategyDirective {
        _ = self.membership.applyReachabilityChange(change)
        let member = change.member

        _ = self._markAsDown.remove(member)
        if self._unreachable.remove(member) != nil {
            return .cancelTimer(key: self.timerKey(member))
        }

        return .none
    }

    func timerKey(_ member: Cluster.Member) -> TimerKey {
        TimerKey(member.uniqueNode)
    }

    func onLeaderChange(to leader: Cluster.Member?) throws -> DowningStrategyDirective {
        _ = try self.membership.applyLeadershipChange(to: leader)

        if self.isLeader, !self._markAsDown.isEmpty {
            defer { self._markAsDown = [] }
            return .markAsDown(members: self._markAsDown)
        } else {
            return .none
        }
    }

    func onMemberRemoved(_ member: Cluster.Member) -> DowningStrategyDirective {
        self._markAsDown.remove(member)

        if self._unreachable.remove(member) != nil {
            return .cancelTimer(key: self.timerKey(member))
        }

        return .none
    }
}

public struct TimeoutBasedDowningStrategySettings {
    /// Provides a slight delay after noticing an `.unreachable` before declaring down.
    ///
    /// Generally with a distributed failure detector such delay may not be necessary, however it is available in case
    /// you want to allow noticing "tings are bad, but don't act on it" environments.
    public var downUnreachableMembersAfter: Duration = .seconds(1)

    public static var `default`: TimeoutBasedDowningStrategySettings {
        .init()
    }
}
