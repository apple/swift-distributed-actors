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

/// The `TimeoutBasedDowningStrategy` marks nodes that have been unreachable as `Down` after a configurable timeout.
///
/// Only the node that is currently the currently assigned leader can make the decision to mark another node as down.
/// Non-leading nodes will keep track of the nodes they would have marked down and do so in case they become leader.
/// If a node becomes reachable again before the timeout expires, it will not be considered for downing anymore.
internal final class TimeoutBasedDowningStrategy {
    let settings: TimeoutBasedDowningStrategySettings
    let selfNode: UniqueNode

    var membership: Membership

    var isLeader: Bool {
        return self.membership.leader?.node == self.selfNode
    }

    // unreachable members will be marked down after the timeout expires
    var _unreachable: Set<UniqueNode>

    // buffer for nodes that will be marked down, if this node becomes the leader
    var _markAsDown: Set<UniqueNode>

    init(_ settings: TimeoutBasedDowningStrategySettings, selfNode: UniqueNode) {
        self.settings = settings
        self.selfNode = selfNode
        self._unreachable = []
        self._markAsDown = []
        self.membership = Membership().joining(selfNode)
    }
}

// FIXME: Implement more in terms of "change" APIs
extension TimeoutBasedDowningStrategy: DowningStrategy {
    func onMemberUnreachable(_ member: Member) -> DowningStrategyDirectives.MemberUnreachableDirective {
        self._unreachable.insert(member.node)

        return .startTimer(key: TimerKey(member.node), message: .timeout(member), delay: self.settings.downUnreachableMembersAfter)
    }

    func onLeaderChange(to leader: Member?) throws -> DowningStrategyDirectives.LeaderChangeDirective {
        _ = try self.membership.applyLeadershipChange(to: leader)

        if self.isLeader, !self._markAsDown.isEmpty {
            defer { self._markAsDown = [] }
            return .markAsDown(self._markAsDown)
        } else {
            return .none
        }
    }

    func onTimeout(_ member: Member) -> DowningStrategyDirectives.TimeoutDirective {
        guard let address = self._unreachable.remove(member.node) else {
            return .none
        }

        if self.isLeader {
            return .markAsDown(address)
        } else {
            self._markAsDown.insert(address)
            return .none
        }
    }

    func onMemberRemoved(_ member: Member) -> DowningStrategyDirectives.MemberRemovedDirective {
        self._markAsDown.remove(member.node)

        if self._unreachable.remove(member.node) != nil {
            return .cancelTimer
        }

        return .none
    }

    func onMemberReachable(_ member: Member) -> DowningStrategyDirectives.MemberReachableDirective {
        self._markAsDown.remove(member.node)

        if self._unreachable.remove(member.node) != nil {
            return .cancelTimer
        }

        return .none
    }
}

public struct TimeoutBasedDowningStrategySettings {
    public var downUnreachableMembersAfter: TimeAmount = .seconds(1)

    public static var `default`: TimeoutBasedDowningStrategySettings {
        return .init()
    }
}
