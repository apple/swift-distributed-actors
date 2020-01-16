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

extension Cluster {
    /// Represents cluster events, most notably regarding membership and reachability of other members of the cluster.
    ///
    /// Inspect them directly, or apply to a `Membership` copy in order to be able to react to membership state of the cluster.
    public enum Event: Equatable {
        case snapshot(Membership)
        case membershipChange(MembershipChange)
        case reachabilityChange(ReachabilityChange)
        case leadershipChange(LeadershipChange)
    }
}
