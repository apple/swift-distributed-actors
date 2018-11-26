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

import NIO
import Swift Distributed ActorsActor

/*
 * Swift Distributed Actors implementation of the classic "Dining Philosophers" problem.
 *
 * The goal of this implementation is not to be efficient or solve the livelock,
 * but rather to be a nice application that continiously "does something" with
 * messaging between various actors.
 *
 * The implementation is based on the following take on the problem:
 * http://www.dalnefre.com/wp/2010/08/dining-philosophers-in-humus
 */
let system = ActorSystem("DiningPhilosophersTests")

// prepare 5 forks, the resources, that the philosophers will compete for:
let fork1: Fork.Ref = try! system.spawn(Fork.behavior, name: "fork-1")
let fork2: Fork.Ref = try! system.spawn(Fork.behavior, name: "fork-2")
let fork3: Fork.Ref = try! system.spawn(Fork.behavior, name: "fork-3")
let fork4: Fork.Ref = try! system.spawn(Fork.behavior, name: "fork-4")
let fork5: Fork.Ref = try! system.spawn(Fork.behavior, name: "fork-5")

// 5 philosophers, sitting in a circle, with the forks between them:
let p1: Philosopher.Ref = try! system.spawn(Philosopher(left: fork5, right: fork1).thinking, name: "Konrad")
let p2: Philosopher.Ref = try! system.spawn(Philosopher(left: fork1, right: fork2).thinking, name: "Dario")
let p3: Philosopher.Ref = try! system.spawn(Philosopher(left: fork2, right: fork3).thinking, name: "Johannes")
let p4: Philosopher.Ref = try! system.spawn(Philosopher(left: fork3, right: fork4).thinking, name: "Cory")
let p5: Philosopher.Ref = try! system.spawn(Philosopher(left: fork4, right: fork5).thinking, name: "Norman")

Thread.sleep(.seconds(10))
