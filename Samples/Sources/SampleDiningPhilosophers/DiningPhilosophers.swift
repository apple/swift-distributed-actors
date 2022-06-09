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

final class DiningPhilosophers {
    private var forks: [Fork] = []
    private var philosophers: [Philosopher] = []

    func run(for duration: Duration) async throws {
        let system = await ClusterSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = Fork(name: "fork-1", actorSystem: system)
        let fork2 = Fork(name: "fork-2", actorSystem: system)
        let fork3 = Fork(name: "fork-3", actorSystem: system)
        let fork4 = Fork(name: "fork-4", actorSystem: system)
        let fork5 = Fork(name: "fork-5", actorSystem: system)
        self.forks = [fork1, fork2, fork3, fork4, fork5]

        // 5 philosophers, sitting in a circle, with the forks between them:
        self.philosophers = [
            Philosopher(name: "Konrad", leftFork: fork5, rightFork: fork1, actorSystem: system),
            Philosopher(name: "Dario", leftFork: fork1, rightFork: fork2, actorSystem: system),
            Philosopher(name: "Johannes", leftFork: fork2, rightFork: fork3, actorSystem: system),
            Philosopher(name: "Cory", leftFork: fork3, rightFork: fork4, actorSystem: system),
            Philosopher(name: "Erik", leftFork: fork4, rightFork: fork5, actorSystem: system),
        ]

        _Thread.sleep(duration)
    }
}
