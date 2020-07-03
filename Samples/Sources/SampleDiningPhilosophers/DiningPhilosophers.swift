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

struct DiningPhilosophers {
    func run(for time: TimeAmount) throws {
        let system = ActorSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1: Fork.Ref = try system.spawn(.prefixed(with: "fork"), Fork.behavior)
        let fork2: Fork.Ref = try system.spawn(.prefixed(with: "fork"), Fork.behavior)
        let fork3: Fork.Ref = try system.spawn(.prefixed(with: "fork"), Fork.behavior)
        let fork4: Fork.Ref = try system.spawn(.prefixed(with: "fork"), Fork.behavior)
        let fork5: Fork.Ref = try system.spawn(.prefixed(with: "fork"), Fork.behavior)

        // 5 philosophers, sitting in a circle, with the forks between them:
        let _: Philosopher.Ref = try system.spawn("Konrad", Philosopher(left: fork5, right: fork1).behavior)
        let _: Philosopher.Ref = try system.spawn("Dario", Philosopher(left: fork1, right: fork2).behavior)
        let _: Philosopher.Ref = try system.spawn("Johannes", Philosopher(left: fork2, right: fork3).behavior)
        let _: Philosopher.Ref = try system.spawn("Cory", Philosopher(left: fork3, right: fork4).behavior)
        let _: Philosopher.Ref = try system.spawn("Norman", Philosopher(left: fork4, right: fork5).behavior)

        try system.park(atMost: time)
    }
}
