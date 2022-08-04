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
import DistributedActors
import struct Foundation.Date
import class Foundation.FileHandle
import struct Foundation.URL
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
                     allNodes multiNodeEndpoints: [MultiNode.Endpoint]) async throws {
        var control = multiNodeTest.makeControl(nodeName)
        control._allNodes = convertAllNodes(allNodes: multiNodeEndpoints)
        let myNode = control._allNodes[nodeName]! // !-safe, we just prepared this node collection

        let actorSystem = await ClusterSystem(nodeName) { settings in
            settings.bindHost = myNode.host
            settings.bindPort = myNode.port

            // we use the singleton to implement a simple Coordinator
            // TODO: if the node hosting the coordinator dies we'd potentially have some races at hand
            //       there's a few ways to solve this... but for now this is good enough.
            settings += ClusterSingletonPlugin()
        }
        control._actorSystem = actorSystem

        // join all the other nodes
        print("JOIN ============================================")
        let otherNodes = control._allNodes.values.filter { $0.systemName != nodeName }
        for other in otherNodes {
            log("Prepare: join [\(nodeName)] with \(other)")
            actorSystem.cluster.join(node: other)
        }

        var allNodes: Set<UniqueNode> = [actorSystem.cluster.uniqueNode]
        for other in otherNodes {
            let joinedOther = try await actorSystem.cluster.joined(node: other, within: .seconds(15)) // TODO: configurable join timeouts
            guard let joinedOther else {
                fatalError("[multi-node][\(nodeName)] Failed to join \(other)!")
            }
            print("[multi-node] [\(actorSystem.cluster.uniqueNode)] <= joined => \(joinedOther)")
            allNodes.insert(joinedOther.uniqueNode)
        }

        let conductorSingletonSettings = ClusterSingletonSettings()
        let conductorName = "$test-conductor"
        let multiNodeSettings = MultiNodeTestSettings()
        let conductor = try await actorSystem.singleton.host(name: conductorName, settings: conductorSingletonSettings) { actorSystem in
            MultiNodeTestConductor(
                name: conductorName,
                allNodes: allNodes,
                settings: multiNodeSettings,
                actorSystem: actorSystem)
        }
        control._conductor = conductor

        print("JOIN END ============================================")

        do {
            print("RUN ============================================")
            print("RUN ============================================")
            print("RUN ============================================")
            try await multiNodeTest.runTest(control)
            print("DONE ============================================")
            print("DONE ============================================")
            print("DONE ============================================")
        } catch {
            log("ERROR[\(nodeName)]: \(error)")
            try await actorSystem.shutdown()
            return
        }

        try await actorSystem.shutdown()
        return
    }

    func convertAllNodes(allNodes: [MultiNode.Endpoint]) -> [String: Node] {
        let nodeList = allNodes.map { mn in
            let n = Node(systemName: mn.name, host: mn.sactHost, port: mn.sactPort)

            return (n.systemName, n)
        }
        return .init(uniqueKeysWithValues: nodeList)
    }
}
