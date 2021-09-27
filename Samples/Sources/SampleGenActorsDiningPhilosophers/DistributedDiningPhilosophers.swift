//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

struct DistributedDiningPhilosophers {
    func run(for time: TimeAmount) throws {
        let systemA = ActorSystem("DistributedPhilosophers") { settings in
            settings.cluster.enabled = true
            settings.cluster.bindPort = 1111
        }
        let systemB = ActorSystem("DistributedPhilosophers") { settings in
            settings.cluster.enabled = true
            settings.cluster.bindPort = 2222
        }
        let systemC = ActorSystem("DistributedPhilosophers") { settings in
            settings.cluster.enabled = true
            settings.cluster.bindPort = 3333
        }

        print("~~~~~~~ started 3 actor systems ~~~~~~~")

        // TODO: Joining to be simplified by having "seed nodes" (that a node should join)
        systemA.cluster.join(node: systemB.settings.cluster.node)
        systemA.cluster.join(node: systemC.settings.cluster.node)
        systemC.cluster.join(node: systemB.settings.cluster.node)

        Thread.sleep(.seconds(2))

        print("~~~~~~~ systems joined each other ~~~~~~~")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = Fork(name: "fork-1", transport: systemA)
        let fork2 = Fork(name: "fork-2", transport: systemB)
        let fork3 = Fork(name: "fork-3", transport: systemB)
        let fork4 = Fork(name: "fork-4", transport: systemC)
        let fork5 = Fork(name: "fork-5", transport: systemC)

        // 5 philosophers, sitting in a circle, with the forks between them:
        let philosopher1 = Philosopher(name: "Konrad", leftFork: fork5, rightFork: fork1, transport: systemA)
        let philosopher2 = Philosopher(name: "Dario", leftFork: fork1, rightFork: fork2, transport: systemB)
        let philosopher3 = Philosopher(name: "Johannes", leftFork: fork2, rightFork: fork3, transport: systemB)
        let philosopher4 = Philosopher(name: "Cory", leftFork: fork3, rightFork: fork4, transport: systemC)
        let philosopher5 = Philosopher(name: "Erik", leftFork: fork4, rightFork: fork5, transport: systemC)

        try systemA.park(atMost: time)
    }
}
