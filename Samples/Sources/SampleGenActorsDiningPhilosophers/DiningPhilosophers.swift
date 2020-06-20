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

struct DiningPhilosophers {
    func run(for time: TimeAmount) throws {
        let system = ActorSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = try system.spawn(.prefixed(with: "fork"), Fork.init)
        let fork2 = try system.spawn(.prefixed(with: "fork"), Fork.init)
        let fork3 = try system.spawn(.prefixed(with: "fork"), Fork.init)
        let fork4 = try system.spawn(.prefixed(with: "fork"), Fork.init)
        let fork5 = try system.spawn(.prefixed(with: "fork"), Fork.init)

        // 5 philosophers, sitting in a circle, with the forks between them:
        _ = try system.spawn("Konrad") { Philosopher(context: $0, leftFork: fork5, rightFork: fork1) }
        _ = try system.spawn("Dario") { Philosopher(context: $0, leftFork: fork1, rightFork: fork2) }
        _ = try system.spawn("Johannes") { Philosopher(context: $0, leftFork: fork2, rightFork: fork3) }
        _ = try system.spawn("Cory") { Philosopher(context: $0, leftFork: fork3, rightFork: fork4) }
        _ = try system.spawn("Erik") { Philosopher(context: $0, leftFork: fork4, rightFork: fork5) }

        __sleep(time)
    }
}
