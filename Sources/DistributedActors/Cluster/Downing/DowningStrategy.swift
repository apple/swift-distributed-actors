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

import Logging

/// EXPERIMENTAL: NOT YET STABLE API
///
/// Allows implementing downing strategies, without having to re-implement and reinvent logging and subscription logic.
/// Downing strategies can focus on inspecting the membership and issuing timers if needed.
public protocol DowningStrategy {
    func onClusterEvent(event: Cluster.Event) throws -> DowningStrategyDirective

    func onTimeout(_ member: Cluster.Member) -> DowningStrategyDirective
}

/// EXPERIMENTAL: NOT STABLE API
public enum DowningStrategyDirective {
    case none
    case markAsDown(Set<Cluster.Member>)
    case startTimer(key: TimerKey, message: DowningStrategyMessage, delay: TimeAmount)
    case cancelTimer(key: TimerKey)

    static func markAsDown(_ member: Cluster.Member) -> Self {
        Self.markAsDown([member])
    }
}

/// EXPERIMENTAL: NOT STABLE API
public enum DowningStrategyMessage: NonTransportableActorMessage {
    case timeout(Cluster.Member)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Downing Shell

internal struct DowningStrategyShell {
    typealias Message = DowningStrategyMessage
    var naming: ActorNaming = "downingStrategy"

    let strategy: DowningStrategy

    init(_ strategy: DowningStrategy) {
        self.strategy = strategy
    }

    var behavior: Behavior<Message> {
        .setup { context in
            let clusterEventSubRef = context.subReceive(Cluster.Event.self) { event in
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
                    let directive = self.strategy.onTimeout(member)
                    context.log.debug("Received timeout for [\(member)], resulting in: \(directive)")
                    self.interpret(context, directive)
                }

                return .same
            }
        }
    }

    func receiveClusterEvent(_ context: ActorContext<Message>, event: Cluster.Event) throws {
        let directive: DowningStrategyDirective = try self.strategy.onClusterEvent(event: event)
        self.interpret(context, directive)
    }

    func interpret(_ context: ActorContext<Message>, _ directive: DowningStrategyDirective) {
        switch directive {
        case .markAsDown(let members):
            self.markAsDown(context, members: members)

        case .startTimer(let key, let message, let delay):
            context.log.trace("Start timer \(key), message: \(message), delay: \(delay)")
            context.timers.startSingle(key: key, message: message, delay: delay)
        case .cancelTimer(let key):
            context.log.trace("Cancel timer \(key)")
            context.timers.cancel(for: key)

        case .none:
            () // nothing to be done
        }
    }

    func markAsDown(_ context: ActorContext<Message>, members: Set<Cluster.Member>) {
        for member in members {
            context.log.info(
                "Decision to [.down] member [\(member)]!",
                metadata: self.metadata.merging(
                    [
                        "downing/member": "\(member)",
                    ],
                    uniquingKeysWith: { l, _ in l }
                )
            )
            context.system.cluster.down(member: member)
        }
    }

    var metadata: Logger.Metadata {
        [
            "tag": "downing",
            "downing/strategy": "\(type(of: self.strategy))",
        ]
    }
}
