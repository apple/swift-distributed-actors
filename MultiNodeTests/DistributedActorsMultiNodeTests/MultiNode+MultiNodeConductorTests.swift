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

/// Tests of the ``MultiNodeTestConductor`` itself.
public final class MultiNodeConductorTests: MultiNodeTestSuite {
    public init() {}

    /// Spawns two nodes: first and second, and forms a cluster with them.
    ///
    /// ## Default execution
    /// Unlike normal unit tests, each node is spawned in a separate process,
    /// allowing is to terminate nodes harshly by terminating entire processes.
    ///
    /// It also eliminates the possibility of "cheating" and a node peeking
    /// at shared state, since the nodes are properly isolated as if in a real cluster.
    public enum Nodes: String, MultiNodeNodes {
        case first
        case second
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
        //        settings.logging.logLevel = .debug
    }

    public let testCrashSecondNode = MultiNodeTest(MultiNodeConductorTests.self) { multiNode in
        // A checkPoint suspends until all nodes have reached it, and then all nodes resume execution.
        try await multiNode.checkPoint("initial")

        // We can execute code only on a specific node:
        multiNode.log.info("Before RUN ON SECOND ------")
        try await multiNode.runOn(.second) { second in
            multiNode.log.info("Before RUN INSIDE SECOND ------")
            multiNode.log.info("SECOND SHUTDOWN")
            try second.shutdown()
            try await second.terminated
            return
        }

        try await multiNode.runOn(.first) { first in
            try await first.cluster.waitFor(multiNode[.second], .down, within: .seconds(30))
        }

        try multiNode.system.shutdown()
        try await multiNode.system.terminated
    }
}
