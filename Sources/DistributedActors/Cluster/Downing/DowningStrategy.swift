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

import Distributed
import Logging

/// Allows implementing downing strategies, without having to re-implement and reinvent logging and subscription logic.
///
/// Downing strategies can focus on inspecting the membership and issuing timers if needed.
public protocol DowningStrategy {
    /// Invoked whenever the cluster emits an event.
    ///
    /// - Parameter event: cluster event that just occurred
    /// - Returns: directive, instructing the cluster to take some specific action.
    /// - Throws: If unable to handle the event for some reason; the failure will be logged and ignored.
    func onClusterEvent(event: Cluster.Event) throws -> DowningStrategyDirective

    func onTimeout(_ member: Cluster.Member) -> DowningStrategyDirective
}

/// Return to instruct the downing shell how to react.
public struct DowningStrategyDirective {
    internal let underlying: Repr
    internal enum Repr {
        case none
        case markAsDown(Set<Cluster.Member>)
        case startTimer(member: Cluster.Member, delay: Duration)
        case cancelTimer(member: Cluster.Member)
    }

    internal init(_ underlying: Repr) {
        self.underlying = underlying
    }

    public static var none: Self {
        .init(.none)
    }

    public static func startTimer(member: Cluster.Member, delay: Duration) -> Self {
        .init(.startTimer(member: member, delay: delay))
    }

    public static func cancelTimer(member: Cluster.Member) -> Self {
        .init(.cancelTimer(member: member))
    }

    public static func markAsDown(members: Set<Cluster.Member>) -> Self {
        .init(.markAsDown(members))
    }

    public static func markAsDown(_ member: Cluster.Member) -> Self {
        .init(.markAsDown([member]))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Downing Shell

internal distributed actor DowningStrategyShell {
    typealias ActorSystem = ClusterSystem

    static let path: ActorPath = try! ActorPath._system.appending(segment: ActorPathSegment("downingStrategy"))

    static var props: _Props {
        var ps = _Props()
        ps._knownActorName = Self.path.name
        ps._systemActor = true
        ps._wellKnown = true
        return ps
    }

    let strategy: DowningStrategy

    private lazy var log = Logger(actor: self)

    /// `Task` for subscribing to cluster events.
    private var eventsListeningTask: Task<Void, Error>?
    /// Timer `Task`s
    private var memberTimerTasks: [Cluster.Member: Task<Void, Error>] = [:]

    init(_ strategy: DowningStrategy, system: ActorSystem) async {
        self.strategy = strategy
        self.actorSystem = system
        self.eventsListeningTask = Task {
            for await event in system.cluster.events {
                try self.receiveClusterEvent(event)
            }
        }
    }

    deinit {
        self.eventsListeningTask?.cancel()
    }

    func receiveClusterEvent(_ event: Cluster.Event) throws {
        let directive: DowningStrategyDirective = try self.strategy.onClusterEvent(event: event)
        self.interpret(directive: directive)
    }

    func interpret(directive: DowningStrategyDirective) {
        switch directive.underlying {
        case .markAsDown(let members):
            self.markAsDown(members: members)

        case .startTimer(let member, let delay):
            self.log.trace("Start timer for member: \(member), delay: \(delay)")
            self.memberTimerTasks[member] = Task {
                defer { self.memberTimerTasks.removeValue(forKey: member) }

                try await Task.sleep(until: .now + delay, clock: .continuous)

                guard !Task.isCancelled else {
                    return
                }

                self.onTimeout(member: member)
            }
        case .cancelTimer(let member):
            self.log.trace("Cancel timer for member: \(member)")
            if let timerTask = self.memberTimerTasks.removeValue(forKey: member) {
                timerTask.cancel()
            }

        case .none:
            () // nothing to be done
        }
    }

    func markAsDown(members: Set<Cluster.Member>) {
        for member in members {
            self.log.info(
                "Decision to [.down] member [\(member)]!", metadata: self.metadata([
                    "downing/node": "\(reflecting: member.uniqueNode)",
                ])
            )
            self.actorSystem.cluster.down(member: member)
        }
    }

    func onTimeout(member: Cluster.Member) {
        let directive = self.strategy.onTimeout(member)
        self.log.debug("Received timeout for [\(member)], resulting in: \(directive)")
        self.interpret(directive: directive)
    }

    var metadata: Logger.Metadata {
        [
            "tag": "downing",
            "downing/strategy": "\(type(of: self.strategy))",
        ]
    }

    func metadata(_ additional: Logger.Metadata) -> Logger.Metadata {
        self.metadata.merging(additional, uniquingKeysWith: { _, r in r })
    }
}
