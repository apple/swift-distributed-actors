//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
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

    func run(for time: TimeAmount) throws {
        let system = ActorSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = Fork(name: "fork-1", transport: system)
        let fork2 = Fork(name: "fork-2", transport: system)
        let fork3 = Fork(name: "fork-3", transport: system)
        let fork4 = Fork(name: "fork-4", transport: system)
        let fork5 = Fork(name: "fork-5", transport: system)
        self.forks = [fork1, fork2, fork3, fork4, fork5]

        // 5 philosophers, sitting in a circle, with the forks between them:
        self.philosophers = [
            Philosopher(name: "Konrad", leftFork: fork5, rightFork: fork1, transport: system),
            Philosopher(name: "Dario", leftFork: fork1, rightFork: fork2, transport: system),
            Philosopher(name: "Johannes", leftFork: fork2, rightFork: fork3, transport: system),
            Philosopher(name: "Cory", leftFork: fork3, rightFork: fork4, transport: system),
            Philosopher(name: "Erik", leftFork: fork4, rightFork: fork5, transport: system),
        ]

        _Thread.sleep(time)
    }
}
