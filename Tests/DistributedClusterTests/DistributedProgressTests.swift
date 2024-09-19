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
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Builder

distributed actor Builder: CustomStringConvertible {
    let probe: ActorTestProbe<String>
    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Romeo init")
    }

    public distributed func build() -> DistributedProgress<BuildSteps>.Box {
        let progress = DistributedProgress(actorSystem: actorSystem, steps: BuildSteps.self)

        Task {
            try await progress.whenLocal { progress in
                try await progress.to(step: .prepare)
                try await Task.sleep(until: .now + .milliseconds(100), clock: .continuous)
                try await progress.to(step: .compile)
                try await Task.sleep(until: .now + .milliseconds(200), clock: .continuous)
                try await progress.to(step: .test)
                try await Task.sleep(until: .now + .milliseconds(200), clock: .continuous)
                try await progress.to(step: .complete)
            }
        }

        return DistributedProgress<BuildSteps>.Box(source: progress)
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

enum BuildSteps: String, DistributedProgressSteps {
    case prepare
    case compile
    case test
    case complete
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Juliet

distributed actor BuildWatcher: CustomStringConvertible {
    lazy var log = Logger(actor: self)

    let probe: ActorTestProbe<String>
    let builder: Builder

    init(probe: ActorTestProbe<String>, builder: Builder, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        self.builder = builder
    }

    distributed func runBuild_waitCompleted() async throws {
        let progress = try await self.builder.build()

        try await progress.completed()
        self.probe.tell("completed")
    }

    distributed func runBuild_streamSteps() async throws {
        let progress = try await self.builder.build()

        for try await step in try await progress.steps() {
            self.probe.tell("received-step:\(step)")
        }
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class DistributedProgressTests: ClusteredActorSystemsXCTestCase, @unchecked Sendable {
    override var captureLogs: Bool {
        false
    }

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

    func test_progress_happyPath() async throws {
        let system = await self.setUpNode("single")

        let pb = self.testKit(system).makeTestProbe(expecting: String.self)
        let pw = self.testKit(system).makeTestProbe(expecting: String.self)
        let p = self.testKit(system).makeTestProbe(expecting: String.self)

        let builder = Builder(probe: pb, actorSystem: system)
        let watcher = BuildWatcher(probe: pw, builder: builder, actorSystem: system)

        Task {
            try await watcher.runBuild_waitCompleted()
            p.tell("done")
        }

        try pw.expectMessage("completed")
        try p.expectMessage("done")
    }

    func test_progress_stream_local() async throws {
        let system = await self.setUpNode("single")
        try await self.impl_progress_stream_cluster(first: system, second: system)
    }

    func test_progress_stream_cluster() async throws {
        let (first, second) = await self.setUpPair()
        try await joinNodes(node: first, with: second)

        try await self.impl_progress_stream_cluster(first: first, second: second)
    }

    func impl_progress_stream_cluster(first: ClusterSystem, second: ClusterSystem) async throws {
        let pb = self.testKit(first).makeTestProbe(expecting: String.self)
        let pw = self.testKit(second).makeTestProbe(expecting: String.self)
        let p = self.testKit(first).makeTestProbe(expecting: String.self)

        let builder = Builder(probe: pb, actorSystem: first)
        let watcher = BuildWatcher(probe: pw, builder: builder, actorSystem: second)

        Task {
            try await watcher.runBuild_streamSteps()
            p.tell("done")
        }

        let messages = try pw.fishForMessages(within: .seconds(5)) { message in
            if message == "received-step:\(BuildSteps.last)" {
                return .catchComplete
            } else {
                return .catchContinue
            }
        }
        pinfo("Received \(messages.count) progress updates: \(messages)")
        messages.shouldEqual(BuildSteps.allCases.suffix(messages.count).map { "received-step:\($0)" })
        try p.expectMessage("done")
    }
}
