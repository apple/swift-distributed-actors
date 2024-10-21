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
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Logging
import Testing

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Romeo

distributed actor Romeo: LifecycleWatch, CustomStringConvertible {
    let probe: ActorTestProbe<String>
    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Romeo init")
    }

    deinit {
//         probe.tell("Romeo deinit")
    }

    distributed func greet(_ greeting: String) {
        // nothing important here
    }

    public func terminated(actor id: ActorID) async {
        // ignore
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Juliet

distributed actor Juliet: LifecycleWatch, CustomStringConvertible {
    let probe: ActorTestProbe<String>
    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Juliet init")
    }

    distributed func meetWatch(_ romeo: Romeo, unwatch doUnwatch: Bool) async throws {
        watchTermination(of: romeo)
        if doUnwatch {
            unwatchTermination(of: romeo)
        }
        self.log.info("Watched \(romeo)")
    }

    public func terminated(actor id: ActorID) async {
        self.log.info("Got terminated: \(id)")
        self.probe.tell("Received terminated: \(id)")
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests
@Suite(.timeLimit(.minutes(1)), .serialized)
struct LifecycleWatchTests {
    var testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
        self.self.testCase.configureLogCapture = { settings in
            settings.excludeActorPaths = [
                "/system/cluster",
                "/system/gossip",
                "/system/cluster/gossip",
                "/system/receptionist",
                "/system/receptionist-ref",
                "/system/cluster/swim",
                "/system/clusterEvents",
            ]
        }
    }

    @Test
    func test_watch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testCase.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testCase.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: self.testCase.system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: self.testCase.system)

            try await juliet.meetWatch(romeo!, unwatch: false)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pj.expectMessage(prefix: "Received terminated: /user/Romeo")
    }

    @Test
    func test_watchThenUnwatch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testCase.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testCase.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: self.testCase.system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: self.testCase.system)

            try await juliet.meetWatch(romeo!, unwatch: true)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pj.expectNoMessage(for: .milliseconds(300))
    }

    @Test
    func test_watch_shouldTriggerTerminatedWhenNodeTerminates() async throws {
        try await shouldNotThrow {
            let pj = self.testCase.testKit.makeTestProbe(expecting: String.self)
            let pr = self.testCase.testKit.makeTestProbe(expecting: String.self)

            let (first, second) = await self.testCase.setUpPair() { settings in
                settings.enabled = true
            }
            try await self.testCase.joinNodes(node: first, with: second, ensureMembers: .up)

            let juliet = Juliet(probe: pj, actorSystem: first)

            let romeo = Romeo(probe: pr, actorSystem: second)
            let remoteRomeo = try! Romeo.resolve(id: romeo.id, using: first)
            try assertRemoteActor(remoteRomeo)

            try await juliet.meetWatch(remoteRomeo, unwatch: false)

            first.cluster.down(endpoint: second.cluster.node.endpoint)

            try pj.expectMessage("Juliet init")
            try pr.expectMessage("Romeo init")
            try pj.expectMessage(prefix: "Received terminated: /user/Romeo", within: .seconds(10))
        }
    }
}
