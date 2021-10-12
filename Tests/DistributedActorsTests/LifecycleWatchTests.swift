//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import Logging
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Romeo

distributed actor Romeo: LifecycleWatchSupport, CustomStringConvertible {
    let probe: ActorTestProbe<String>

    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, transport: ActorTransport) {
        defer { transport.actorReady(self) }
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

distributed actor Juliet: LifecycleWatchSupport, CustomStringConvertible {
    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, transport: ActorTransport) {
        defer { transport.actorReady(self) }
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

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class DeathWatchDistributedTests: ActorSystemXCTestCase {

    func test_watch_shouldTriggerTerminatedWhenWatchedActorDeinits() throws {
        try runAsyncAndBlock {
            let pj = testKit.spawnTestProbe(expecting: String.self)
            let pr = testKit.spawnTestProbe(expecting: String.self)
            let juliet = Juliet(probe: pj, transport: system)

            func meet() async throws {
                var romeo: Romeo? = Romeo(probe: pr, transport: system)

                try await juliet.meetWatchCallback(romeo!, unwatch: false)
                romeo = nil
            }
            try await meet()

            try pj.expectMessage("Juliet init")
            try pr.expectMessage("Romeo init")
            try pr.expectMessage("Romeo deinit")
            try pj.expectMessage("Received terminated: AnyActorIdentity(/user/Romeo-b)")
        }
    }

    func test_watchThenUnwatch_shouldTriggerTerminatedWhenWatchedActorDeinits() throws {
        try runAsyncAndBlock {
            let pj = testKit.spawnTestProbe(expecting: String.self)
            let pr = testKit.spawnTestProbe(expecting: String.self)
            let juliet = Juliet(probe: pj, transport: system)

            func meet() async throws {
                var romeo: Romeo? = Romeo(probe: pr, transport: system)

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
}