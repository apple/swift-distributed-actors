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
    func onLeaderChange(to: Member?) throws -> DowningStrategyDirectives.LeaderChangeDirective
    func onTimeout(_ member: Member) -> DowningStrategyDirectives.TimeoutDirective

    func onMemberUnreachable(_ member: Member) -> DowningStrategyDirectives.MemberUnreachableDirective
    func onMemberReachable(_ member: Member) -> DowningStrategyDirectives.MemberReachableDirective

    func onMemberRemoved(_ member: Member) -> DowningStrategyDirectives.MemberRemovedDirective
}

internal enum DowningStrategyDirectives {
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

internal struct DowningStrategyShell {
    typealias Message = DowningStrategyMessage
    var naming: ActorNaming = "downingStrategy"

    let strategy: DowningStrategy

    init(_ strategy: DowningStrategy) {
        self.strategy = strategy
    }

    var behavior: Behavior<Message> {
        return .setup { context in
            let clusterEventSubRef = context.subReceive(ClusterEvent.self) { event in
                do {
                    try self.receiveClusterEvent(context, event: event)
                } catch {
                    context.log.warning("Error while handling cluster event: [\(error)]\(type(of: error))")
                }
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
        context.system.cluster.down(node: member)
    }

    func receiveClusterEvent(_ context: ActorContext<Message>, event: ClusterEvent) throws {
        switch event {
        case .snapshot(let membership):
            () // ignore, we don't need the full membership for decisions // TODO: or do we...
        case .leadershipChange(let change):
            let directive = try self.strategy.onLeaderChange(to: change.newLeader)
            switch directive {
            case .markAsDown(let downMembers):
                self.markAsDown(context, members: downMembers)
            case .none:
                () // no members to mark down
            }

        case .membershipChange(let change) where change.isRemoval:
            context.log.debug("Member [\(change.member)] has been removed")
            let directive = self.strategy.onMemberRemoved(change.member)
            switch directive {
            case .cancelTimer:
                context.timers.cancel(for: TimerKey(change.member))
            case .none:
                () // this member was not marked unreachable, so ignore
            }
        case .membershipChange: // TODO: actually store and act based on membership
            () //

        case .reachabilityChange(let change):
            context.log.debug("Member [\(change)] has become \(change.member.reachability)")

            if change.toReachable {
                let directive = self.strategy.onMemberReachable(change.member)
                switch directive {
                case .cancelTimer:
                    context.timers.cancel(for: TimerKey(change.member.node))
                case .none:
                    () // this member was not marked unreachable, so ignore
                }
            } else {
                switch self.strategy.onMemberUnreachable(change.member) {
                case .startTimer(let key, let message, let delay):
                    context.timers.startSingle(key: key, message: message, delay: delay)
                case .none:
                    () // nothing to be done
                }
            }
        }
    }
}
