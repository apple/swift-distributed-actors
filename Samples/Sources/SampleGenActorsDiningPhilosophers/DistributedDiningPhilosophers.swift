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

        __sleep(.seconds(2))

        print("~~~~~~~ systems joined each other ~~~~~~~")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = try systemA.spawn("fork1", Fork.init)
        let fork2 = try systemB.spawn("fork2", Fork.init)
        let fork3 = try systemB.spawn("fork3", Fork.init)
        let fork4 = try systemC.spawn("fork4", Fork.init)
        let fork5 = try systemC.spawn("fork5", Fork.init)

        // 5 philosophers, sitting in a circle, with the forks between them:
        _ = try systemA.spawn("Konrad") { Philosopher(context: $0, leftFork: fork5, rightFork: fork1) }
        _ = try systemB.spawn("Dario") { Philosopher(context: $0, leftFork: fork1, rightFork: fork2) }
        _ = try systemB.spawn("Johannes") { Philosopher(context: $0, leftFork: fork2, rightFork: fork3) }
        _ = try systemC.spawn("Cory") { Philosopher(context: $0, leftFork: fork3, rightFork: fork4) }
        _ = try systemC.spawn("Norman") { Philosopher(context: $0, leftFork: fork4, rightFork: fork5) }

        systemA.park(atMost: time)
    }
}
