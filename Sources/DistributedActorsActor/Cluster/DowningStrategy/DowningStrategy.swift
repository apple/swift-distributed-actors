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

internal protocol DowningStrategy {
    func onMemberUnreachable(_ member: Member) -> DowningStrategyDirective.MemberUnreachableDirective
    func onLeaderChange(to: UniqueNode?) -> DowningStrategyDirective.LeaderChangeDirective
    func onTimeout(_ member: Member) -> DowningStrategyDirective.TimeoutDirective
    func onMemberRemoved(_ member: Member) -> DowningStrategyDirective.MemberRemovedDirective
    func onMemberReachable(_ member: Member) -> DowningStrategyDirective.MemberReachableDirective
}

internal enum DowningStrategyDirective {
    enum LeaderChangeDirective {
        case none
        case markAsDown(Set<UniqueNode>)
    }

    enum TimeoutDirective {
        case none
        case markAsDown(UniqueNode)
    }

    enum MemberReachableDirective {
        case none
        case cancelTimer
    }

    enum MemberRemovedDirective {
        case none
        case cancelTimer
    }

    enum MemberUnreachableDirective {
        case none
        case startTimer(key: TimerKey, message: DowningStrategyMessage, delay: TimeAmount)
    }
}

internal enum DowningStrategyMessage {
    case timeout(Member)
}

internal struct DowningStrategyShell<Strategy: DowningStrategy> {
    typealias Message = DowningStrategyMessage

    var name: String = "downingStrategy"

    let strategy: Strategy

    init(_ strategy: Strategy) {
        self.strategy = strategy
    }

    var behavior: Behavior<Message> {
        return .setup { context in
            let clusterEventSubRef = context.subReceive(ClusterEvent.self) { event in
                self.receiveClusterEvent(context, event: event)
            }
            context.system.cluster.events.subscribe(clusterEventSubRef)

            return .receiveMessage { message in
                switch message {
                case .timeout(let member):
                    context.log.debug("Received timeout for [\(member)]")
                    switch self.strategy.onTimeout(member) {
                    case .markAsDown(let node):
                        self.markAsDown(context, member: node)
                    case .none:
                        () // nothing to be done
                    }
                }

                return .same
            }
        }
    }

    func markAsDown(_ context: ActorContext<Message>, members: Set<UniqueNode>) {
        for member in members {
            self.markAsDown(context, member: member)
        }
    }

    func markAsDown(_ context: ActorContext<Message>, member: UniqueNode) {
        context.log.info("Strategy [\(type(of: self.strategy))] decision about unreachable member [\(member)]: marking as: DOWN")
        context.system.clusterShell.tell(.command(.down(member)))
    }

    func receiveClusterEvent(_ context: ActorContext<Message>, event: ClusterEvent) {
        switch event {
        case .leaderChanged(let leaderOpt):
            let directive = self.strategy.onLeaderChange(to: leaderOpt)
            switch directive {
            case .markAsDown(let downMembers):
                self.markAsDown(context, members: downMembers)
            case .none:
                () // no members to mark down
            }

        case .reachability(.memberReachable(let member)):
            context.log.debug("Member [\(member)] has become reachable")
            let directive = self.strategy.onMemberReachable(member)
            switch directive {
            case .cancelTimer:
                context.timers.cancel(for: TimerKey(member))
            case .none:
                () // this member was not marked unreachable, so ignore
            }

        case .reachability(.memberUnreachable(let member)):
            context.log.debug("Member [\(member)] has become unreachable")
            switch self.strategy.onMemberUnreachable(member) {
            case .startTimer(let key, let message, let delay):
                context.timers.startSingle(key: key, message: message, delay: delay)
            case .none:
                () // nothing to be done
            }

        case .membership(.memberRemoved(let member)):
            context.log.debug("Member [\(member)] has been removed")
            let directive = self.strategy.onMemberRemoved(member)
            switch directive {
            case .cancelTimer:
                context.timers.cancel(for: TimerKey(member))
            case .none:
                () // this member was not marked unreachable, so ignore
            }

        default:
            () // no need to handle the other events
        }
    }
}
