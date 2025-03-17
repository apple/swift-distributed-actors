//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster
import MultiNodeTestKit
import Logging

public final class MultiNodeClusterSingletonTests: MultiNodeTestSuite {
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
            "OperationLogDistributedReceptionist.swift",
            "Gossiper+Shell.swift",
        ]

        settings.installPrettyLogger = true
    }

    public static func configureActorSystem(settings: inout ClusterSystemSettings) {
        settings.logging.logLevel = .debug

        settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
        // settings += ClusterSingletonPlugin() // already installed by MultiNodeTestSuite
    }

    static var singletonSettings: ClusterSingletonSettings {
        var settings = ClusterSingletonSettings()
        settings.allocationStrategy = .byLeadership
        settings.allocationTimeout = .seconds(15)
        return settings
    }

    public let test_singleton_fromManyNodes = MultiNodeTest(MultiNodeClusterSingletonTests.self) { multiNode in
        let singletonName = "the-one"

        // All nodes run the same code to "host" the singleton (with a different greeting each)
        let ref = try await multiNode.system.singleton.host(name: singletonName, settings: MultiNodeClusterSingletonTests.singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-\(actorSystem.name)", actorSystem: actorSystem)
        }

        try await multiNode.checkPoint("Hosted singleton")  // ----------------------------------------------------------
        let reply = try await ref.greet(name: "Hello from \(multiNode.system.name)")
        print("[ON: \(multiNode.system.name)] Got reply: \(reply)")

        try await multiNode.checkPoint("Got reply from singleton")  // --------------------------------------------------
        // Since now all nodes have made a message exchange with the singleton, we can exit this process.
        // This barrier is important in so that we don't exit the host of the singleton WHILE the others are still getting to talking to it.
    }

    distributed actor TheSingleton: ClusterSingleton {
        typealias ActorSystem = ClusterSystem

        private let greeting: String

        init(greeting: String, actorSystem: ActorSystem) {
            self.actorSystem = actorSystem
            self.greeting = greeting
        }

        distributed func greet(name: String) -> String {
            "\(self.greeting) \(name)! (from node: \(self.id.node), id: \(self.id.detailedDescription))"
        }
    }
}
