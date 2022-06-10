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

import DistributedActors

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
        systemA.cluster.join(node: systemB.settings.node)
        systemA.cluster.join(node: systemC.settings.node)
        systemC.cluster.join(node: systemB.settings.node)

        print("waiting for cluster to form...")
        // TODO: implement this using "await join cluster" API [#948](https://github.com/apple/swift-distributed-actors/issues/948)
        while !(try await self.isClusterFormed(systems)) {
            let nanosInSecond: UInt64 = 1_000_000_000
            try await Task.sleep(nanoseconds: 1 * nanosInSecond)
        }

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

    private func isClusterFormed(_ systems: [ClusterSystem]) async throws -> Bool {
        for system in systems {
            let upCount = try await system.cluster.membershipSnapshot.count(withStatus: .up)
            if upCount != systems.count {
                return false
            }
        }
        return true
    }
}
