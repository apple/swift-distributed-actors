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
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import Logging
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Romeo

distributed actor Romeo: LifecycleWatch, CustomStringConvertible {
    typealias ActorSystem = ClusterSystem

    let probe: ActorTestProbe<String>
    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Romeo init")
    }

    deinit {
        probe.tell("Romeo deinit")
    }

    distributed func greet(_ greeting: String) {
        // nothing important here
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Juliet

distributed actor Juliet: LifecycleWatch, CustomStringConvertible {
    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Juliet init")
    }

    distributed func meetWatchCallback(
        _ romeo: Romeo,
        unwatch doUnwatch: Bool
    ) async throws {
        watchTermination(of: romeo) { terminatedIdentity in
            probe.tell("Received terminated: \(terminatedIdentity)")
        }
        if doUnwatch {
            unwatch(romeo)
        }
    }

    distributed func meetWatchAsyncCallback(
        _ romeo: Romeo,
        unwatch doUnwatch: Bool
    ) async throws {
        @Sendable
        func asyncTerminated(_ terminatedIdentity: ClusterSystem.ActorID) async {
            await self.probe.tell("Received terminated: \(terminatedIdentity)")
        }

        watchTermination(of: romeo, whenTerminated: asyncTerminated)

        if doUnwatch {
            unwatch(romeo)
        }
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class LifecycleWatchTests: ActorSystemXCTestCase, @unchecked Sendable {
    func test_watch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: system)

            try await juliet.meetWatchCallback(romeo!, unwatch: false)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pr.expectMessage("Romeo deinit")
        try pj.expectMessage("Received terminated: /user/Romeo-b")
    }

    func test_watch_shouldTriggerTerminatedWhenWatchedActorDeinits_async() async throws {
        let pj = self.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: system)

            try await juliet.meetWatchAsyncCallback(romeo!, unwatch: false)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pr.expectMessage("Romeo deinit")
        try pj.expectMessage("Received terminated: /user/Romeo-b")
    }

    func test_watchThenUnwatch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: system)

            try await juliet.meetWatchCallback(romeo!, unwatch: true)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pr.expectMessage("Romeo deinit")
        try pj.expectNoMessage(for: .milliseconds(300))
    }
}
