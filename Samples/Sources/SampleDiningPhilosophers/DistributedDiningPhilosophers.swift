//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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
        let fork1: Fork.Ref = try systemA.spawn("fork-1", Fork.behavior)
        let fork2: Fork.Ref = try systemB.spawn("fork-2", Fork.behavior)
        let fork3: Fork.Ref = try systemB.spawn("fork-3", Fork.behavior)
        let fork4: Fork.Ref = try systemC.spawn("fork-4", Fork.behavior)
        let fork5: Fork.Ref = try systemC.spawn("fork-5", Fork.behavior)

        // 5 philosophers, sitting in a circle, with the forks between them:
        _ = try systemA.spawn("Konrad", Philosopher(left: fork5, right: fork1).behavior)
        _ = try systemB.spawn("Dario", Philosopher(left: fork1, right: fork2).behavior)
        _ = try systemB.spawn("Johannes", Philosopher(left: fork2, right: fork3).behavior)
        _ = try systemC.spawn("Cory", Philosopher(left: fork3, right: fork4).behavior)
        _ = try systemC.spawn("Norman", Philosopher(left: fork4, right: fork5).behavior)

        systemA.park(atMost: time)
    }
}
