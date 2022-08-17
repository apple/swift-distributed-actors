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

import ArgumentParser
import Dispatch
import DistributedActors
import struct Foundation.Date
import class Foundation.FileHandle
import class Foundation.ProcessInfo
import struct Foundation.URL
import Logging
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Code executing on each specific process/node

extension MultiNodeTestKitRunnerBoot {
    /// Within a dedicated process, execute the test with the specific node:
    func executeTest(multiNodeTest: MultiNodeTest,
                     nodeName: String,
                     allNodes multiNodeEndpoints: [MultiNode.Endpoint]) async throws
    {
        var control = multiNodeTest.makeControl(nodeName)
        control._allNodes = convertAllNodes(allNodes: multiNodeEndpoints)
        let myNode = control._allNodes[nodeName]! // !-safe, we just prepared this node collection

        var multiNodeSettings = MultiNodeTestSettings()
        multiNodeTest.configureMultiNodeTest(&multiNodeSettings)

        if let waitBeforeBootstrap = multiNodeSettings.waitBeforeBootstrap {
            await prettyWait(
                seconds: waitBeforeBootstrap.seconds,
                hint: "before starting actor system (allow e.g. attaching lldb)"
            )
        }

        let actorSystem = await ClusterSystem(nodeName) { settings in
            settings.bindHost = myNode.host
            settings.bindPort = myNode.port

            /// By default get better backtraces in case we crash:
            settings.installSwiftBacktrace = true

            /// Configure a nicer logger, that pretty prints metadata and also includes source location of logs
            if multiNodeSettings.installPrettyLogger {
                settings.logging.baseLogger = Logger(label: nodeName, factory: { label in
                    PrettyMultiNodeLogHandler(nodeName: label, settings: multiNodeSettings.logCapture)
                })
            }

            // we use the singleton to implement a simple Coordinator
            // TODO: if the node hosting the coordinator dies we'd potentially have some races at hand
            //       there's a few ways to solve this... but for now this is good enough.
            settings += ClusterSingletonPlugin()

            multiNodeTest.configureActorSystem(&settings)
        }
        control._actorSystem = actorSystem

        let signalQueue = DispatchQueue(label: "multi.node.\(multiNodeTest.testSuiteName).\(multiNodeTest.testName).\(nodeName).SignalHandlerQueue")
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        signalSource.setEventHandler {
            signalSource.cancel()
            print("\n[multi-node] received signal, initiating shutdown which should complete after the last request finished.")

            try! actorSystem.shutdown()
        }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()

        // join all the other nodes
        print("CLUSTER JOIN ============================================".yellow)
        let otherNodes = control._allNodes.values.filter { $0.systemName != nodeName }
        for other in otherNodes {
            log("Prepare cluster: join [\(nodeName)] with \(other)")
            actorSystem.cluster.join(node: other)
        }

        var allNodes: Set<UniqueNode> = [actorSystem.cluster.uniqueNode]
        for other in otherNodes {
            let joinedOther = try await actorSystem.cluster.joined(node: other, within: multiNodeSettings.initialJoinTimeout)
            guard let joinedOther else {
                fatalError("[multi-node][\(nodeName)] Failed to join \(other)!")
            }
            print("[multi-node] [\(actorSystem.cluster.uniqueNode)] <= joined => \(joinedOther)")
            allNodes.insert(joinedOther.uniqueNode)
        }

        let conductorSingletonSettings = ClusterSingletonSettings()
        let conductorName = "$test-conductor"
        let conductor = try await actorSystem.singleton.host(name: conductorName, settings: conductorSingletonSettings) { [allNodes, multiNodeSettings] actorSystem in
            MultiNodeTestConductor(
                name: conductorName,
                allNodes: allNodes,
                settings: multiNodeSettings,
                actorSystem: actorSystem
            )
        }
        control._conductor = conductor
        let pong = try await conductor.ping(message: "init", from: "\(actorSystem.name)")
        log("Conductor ready, pong reply: \(pong)")

        do {
            print("TEST RUN ============================================".yellow)
            try await multiNodeTest.runTest(control)
            print("TEST DONE ============================================".green)
        } catch {
            print("TEST FAILED ============================================".red)
            // we'll crash the entire process shortly, no clean shutdown here.
            throw error
        }

        try actorSystem.shutdown()
    }

    func convertAllNodes(allNodes: [MultiNode.Endpoint]) -> [String: Node] {
        let nodeList = allNodes.map { mn in
            let n = Node(systemName: mn.name, host: mn.sactHost, port: mn.sactPort)

            return (n.systemName, n)
        }
        return .init(uniqueKeysWithValues: nodeList)
    }
}
