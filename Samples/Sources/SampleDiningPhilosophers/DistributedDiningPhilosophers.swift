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

import DistributedCluster

final class DistributedDiningPhilosophers {
    private var forks: [Fork] = []
    private var philosophers: [Philosopher] = []

    func run(for duration: Duration) async throws {
        let systemA = await ClusterSystem("Node-A") { settings in
            settings.bindPort = 1111
        }
        let systemB = await ClusterSystem("Node-B") { settings in
            settings.bindPort = 2222
            settings.logging.logLevel = .error
        }
        let systemC = await ClusterSystem("Node-C") { settings in
            settings.bindPort = 3333
            settings.logging.logLevel = .error
        }
        let systems = [systemA, systemB, systemC]

        print("~~~~~~~ started \(systems.count) actor systems ~~~~~~~")

        // TODO: Joining to be simplified by having "seed nodes" (that a node should join)
        systemA.cluster.join(endpoint: systemB.settings.endpoint)
        systemA.cluster.join(endpoint: systemC.settings.endpoint)
        systemC.cluster.join(endpoint: systemB.settings.endpoint)

        print("waiting for cluster to form...")
        try await self.ensureCluster(systems, within: .seconds(10))

        print("~~~~~~~ systems joined each other ~~~~~~~")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        // Node A
        let fork1 = Fork(name: "fork-1", actorSystem: systemA)
        // Node B
        let fork2 = Fork(name: "fork-2", actorSystem: systemB)
        let fork3 = Fork(name: "fork-3", actorSystem: systemB)
        // Node C
        let fork4 = Fork(name: "fork-4", actorSystem: systemC)
        let fork5 = Fork(name: "fork-5", actorSystem: systemC)
        self.forks = [fork1, fork2, fork3, fork4, fork5]

        // 5 philosophers, sitting in a circle, with the forks between them:
        self.philosophers = [
            // Node A
            Philosopher(name: "Konrad", leftFork: fork5, rightFork: fork1, actorSystem: systemA),
            // Node B
            Philosopher(name: "Dario", leftFork: fork1, rightFork: fork2, actorSystem: systemB),
            Philosopher(name: "Johannes", leftFork: fork2, rightFork: fork3, actorSystem: systemB),
            // Node C
            Philosopher(name: "Cory", leftFork: fork3, rightFork: fork4, actorSystem: systemC),
            Philosopher(name: "Erik", leftFork: fork4, rightFork: fork5, actorSystem: systemC),
        ]

        try systemA.park(atMost: duration)
    }

    private func ensureCluster(_ systems: [ClusterSystem], within: Duration) async throws {
        let nodes = Set(systems.map(\.settings.bindNode))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for system in systems {
                group.addTask {
                    try await system.cluster.waitFor(nodes, .up, within: within)
                }
            }
            // loop explicitly to propagagte any error that might have been thrown
            for try await _ in group {}
        }
    }
}
