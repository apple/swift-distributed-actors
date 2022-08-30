//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import MultiNodeTestKit

public final class MultiNodeReceptionistTests: MultiNodeTestSuite {
    public init() {}

    public enum Nodes: String, MultiNodeNodes {
        case first
        case second
        case third
        case fourth
    }

    public static func configureMultiNodeTest(settings: inout MultiNodeTestSettings) {
        settings.dumpNodeLogs = .always

        settings.logCapture.excludeGrep = [
            "SWIMActor.swift", "SWIMInstance.swift",
            "Gossiper+Shell.swift",
        ]

        settings.installPrettyLogger = true
    }

    public static func configureActorSystem(settings: inout ClusterSystemSettings) {
        settings.logging.logLevel = .debug

        settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
    }

    public let test_receptionist_checkIn = MultiNodeTest(MultiNodeReceptionistTests.self) { multiNode in
        // *All* nodes spawn an echo actor
        let localEcho = await DistributedEcho(greeting: "Hi from \(multiNode.system.name), ", actorSystem: multiNode.system)

        try await multiNode.checkPoint("Spawned actors") // ------------------------------------------------------------

        let expectedCount = Nodes.allCases.count
        var discovered: Set<DistributedEcho> = []
        for try await actor in await multiNode.system.receptionist.listing(of: .init(DistributedEcho.self)) {
            multiNode.log.notice("Discovered \(actor.id) from \(actor.id.uniqueNode)")
            discovered.insert(actor)

            if discovered.count == expectedCount {
                break
            }
        }

        try await multiNode.checkPoint("All members found \(expectedCount) actors") // ---------------------------------
    }

    distributed actor DistributedEcho {
        typealias ActorSystem = ClusterSystem

        @ActorID.Metadata(\.receptionID)
        var receptionID: String

        private let greeting: String

        init(greeting: String, actorSystem: ActorSystem) async {
            self.actorSystem = actorSystem
            self.greeting = greeting
            self.receptionID = "*"

            await actorSystem.receptionist.checkIn(self)
        }

        distributed func echo(name: String) -> String {
            "echo: \(self.greeting)\(name)! (from node: \(self.id.uniqueNode), id: \(self.id.detailedDescription))"
        }
    }
}
