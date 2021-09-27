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

struct DiningPhilosophers {
    func run(for time: TimeAmount) throws {
        let system = ActorSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = Fork(name: "fork-1", transport: system)
        let fork2 = Fork(name: "fork-2", transport: system)
        let fork3 = Fork(name: "fork-3", transport: system)
        let fork4 = Fork(name: "fork-4", transport: system)
        let fork5 = Fork(name: "fork-5", transport: system)

        // 5 philosophers, sitting in a circle, with the forks between them:
        let philosopher1 = Philosopher(name: "Konrad", leftFork: fork5, rightFork: fork1, transport: system)
        let philosopher2 = Philosopher(name: "Dario", leftFork: fork1, rightFork: fork2, transport: system)
        let philosopher3 = Philosopher(name: "Johannes", leftFork: fork2, rightFork: fork3, transport: system)
        let philosopher4 = Philosopher(name: "Cory", leftFork: fork3, rightFork: fork4, transport: system)
        let philosopher5 = Philosopher(name: "Erik", leftFork: fork4, rightFork: fork5, transport: system)

        Thread.sleep(time)
    }
}
