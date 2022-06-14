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

    // FIXME(distributed): Should not need to be distributed: https://github.com/apple/swift/pull/59397
    public distributed func terminated(actor id: ActorID) async throws {
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

    // FIXME(distributed): Should not need to be distributed: https://github.com/apple/swift/pull/59397
    public distributed func terminated(actor id: ActorID) async { // not REALLY distributed...
        self.log.info("Got terminated: \(id)")
        self.probe.tell("Received terminated: \(id)")
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class LifecycleWatchTests: ClusterSystemXCTestCase, @unchecked Sendable {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
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

    func test_watch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: system)

            try await juliet.meetWatch(romeo!, unwatch: false)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pj.expectMessage(prefix: "Received terminated: /user/Romeo")
    }

    func test_watchThenUnwatch_shouldTriggerTerminatedWhenWatchedActorDeinits() async throws {
        let pj = self.testKit.makeTestProbe(expecting: String.self)
        let pr = self.testKit.makeTestProbe(expecting: String.self)
        let juliet = Juliet(probe: pj, actorSystem: system)

        func meet() async throws {
            var romeo: Romeo? = Romeo(probe: pr, actorSystem: system)

            try await juliet.meetWatch(romeo!, unwatch: true)
            romeo = nil
        }
        try await meet()

        try pj.expectMessage("Juliet init")
        try pr.expectMessage("Romeo init")
        try pj.expectNoMessage(for: .milliseconds(300))
    }

    func test_watch_shouldTriggerTerminatedWhenNodeTerminates() async throws {
        try await shouldNotThrow {
            let pj = self.testKit.makeTestProbe(expecting: String.self)
            let pr = self.testKit.makeTestProbe(expecting: String.self)

            let (first, second) = await self.setUpPair() { settings in
                settings.enabled = true
            }
            try await joinNodes(node: first, with: second, ensureMembers: .up)

            let juliet = Juliet(probe: pj, actorSystem: first)

            let romeo = Romeo(probe: pr, actorSystem: second)
            let remoteRomeo = try! Romeo.resolve(id: romeo.id, using: first)
            try assertRemoteActor(remoteRomeo)

            try await juliet.meetWatch(remoteRomeo, unwatch: false)

            first.cluster.down(node: second.cluster.uniqueNode.node)

            try pj.expectMessage("Juliet init")
            try pr.expectMessage("Romeo init")
            try pj.expectMessage(prefix: "Received terminated: /user/Romeo", within: .seconds(10))
        }
    }
}
