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

/// Changes in the cluster membership state, are emitted
public enum ClusterEvent: Equatable {
    case leadershipChange(LeadershipChange)
    case membershipChange(MembershipChange)
    case reachabilityChange(ReachabilityChange)
    // TODO: snapshot()?
}

/// Emitted when a change in leader is decided.
public struct LeadershipChange: Equatable {
    // let role: Role if this leader was of a specific role, carry the info here? same for DC?
    let oldLeader: Member?
    let newLeader: Member?
}

public struct ReachabilityChange: Equatable {
    let member: Member

    /// This change is to a `.reachable` state of the `Member`
    var toReachable: Bool {
        return self.member.reachability == .reachable
    }

    /// This change is to a `.unreachable` state of the `Member`
    var toUnreachable: Bool {
        return self.member.reachability == .unreachable
    }
}
