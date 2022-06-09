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
        case startTimer(key: TimerKey, member: Cluster.Member, delay: Duration)
        case cancelTimer(key: TimerKey)
    }

    internal init(_ underlying: Repr) {
        self.underlying = underlying
    }

    public static var none: Self {
        .init(.none)
    }

    public static func startTimer(key: TimerKey, member: Cluster.Member, delay: Duration) -> Self {
        .init(.startTimer(key: key, member: member, delay: delay))
    }

    public static func cancelTimer(key: TimerKey) -> Self {
        .init(.cancelTimer(key: key))
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

    private lazy var timers = ActorTimers<DowningStrategyShell>(self)

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

        case .startTimer(let key, let member, let delay):
            self.log.trace("Start timer \(key), member: \(member), delay: \(delay)")
            self.timers.startSingle(key: key, delay: delay) {
                self.onTimeout(member: member)
            }
        case .cancelTimer(let key):
            self.log.trace("Cancel timer \(key)")
            self.timers.cancel(for: key)

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
