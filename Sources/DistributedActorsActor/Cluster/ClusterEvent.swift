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

enum ClusterEvent {
    case leaderChanged(UniqueNode?)
    case membership(MembershipEvent)
    case reachability(ReachabilityEvent)
}

enum MembershipEvent {
    case memberJoining(Member)
    case memberUp(Member)
    case memberLeaving(Member)
    case memberDown(Member)
    case memberRemoved(Member)
}

enum ReachabilityEvent {
    case memberReachable(Member)
    case memberUnreachable(Member)
}
