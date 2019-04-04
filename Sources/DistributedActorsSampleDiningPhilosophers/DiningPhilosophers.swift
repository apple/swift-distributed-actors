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

import Swift Distributed ActorsActor

struct DiningPhilosophers {
    func run(`for` time: TimeAmount) throws {

        let system = ActorSystem("Philosophers")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1: Fork.Ref = try system.spawn(Fork.behavior, name: "fork-1")
        let fork2: Fork.Ref = try system.spawn(Fork.behavior, name: "fork-2")
        let fork3: Fork.Ref = try system.spawn(Fork.behavior, name: "fork-3")
        let fork4: Fork.Ref = try system.spawn(Fork.behavior, name: "fork-4")
        let fork5: Fork.Ref = try system.spawn(Fork.behavior, name: "fork-5")

        // 5 philosophers, sitting in a circle, with the forks between them:
        let _: Philosopher.Ref = try system.spawn(Philosopher(left: fork5, right: fork1).behavior, name: "Konrad")
        let _: Philosopher.Ref = try system.spawn(Philosopher(left: fork1, right: fork2).behavior, name: "Dario")
        let _: Philosopher.Ref = try system.spawn(Philosopher(left: fork2, right: fork3).behavior, name: "Johannes")
        let _: Philosopher.Ref = try system.spawn(Philosopher(left: fork3, right: fork4).behavior, name: "Cory")
        let _: Philosopher.Ref = try system.spawn(Philosopher(left: fork4, right: fork5).behavior, name: "Norman")

        Thread.sleep(time)
    }
}
