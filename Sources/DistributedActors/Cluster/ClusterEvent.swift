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

/// Represents cluster events, most notably regarding membership and reachability of other members of the cluster.
///
/// Inspect them directly, or apply to a `Membership` copy in order to be able to react to membership state of the cluster.
public enum ClusterEvent: Equatable {
    case snapshot(Membership)
    case membershipChange(MembershipChange)
    case reachabilityChange(ReachabilityChange)
    case leadershipChange(LeadershipChange)
}

/// Emitted when the reachability of a member changes, as determined by a failure detector (e.g. `SWIM`).
public struct ReachabilityChange: Equatable {
    public let member: Member

    /// This change is to a `.reachable` state of the `Member`
    public var toReachable: Bool {
        self.member.reachability == .reachable
    }

    /// This change is to a `.unreachable` state of the `Member`
    public var toUnreachable: Bool {
        self.member.reachability == .unreachable
    }
}
