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

/// The `NoopDowningStrategy` - as the name suggest - does not act on any events and instead always
/// returns `.none` as the directive. This means that nodes that are detected to be unreachable will never
/// be marked down and can always come back and re-join the cluster.
internal struct NoopDowningStrategy: DowningStrategy {
    func onMemberUnreachable(_ member: Member) -> DowningStrategyDirective.MemberUnreachableDirective {
        return .none
    }

    func onLeaderChange(to: UniqueNode?) -> DowningStrategyDirective.LeaderChangeDirective {
        return .none
    }

    func onTimeout(_ member: Member) -> DowningStrategyDirective.TimeoutDirective {
        return .none
    }

    func onMemberReachable(_ member: Member) -> DowningStrategyDirective.MemberReachableDirective {
        return .none
    }

    func onMemberRemoved(_ member: Member) -> DowningStrategyDirective.MemberRemovedDirective {
        return .none
    }
}
