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
 * The goal of this implementation is not to be efficient or solve the live-lock,
 * but rather to be a nice application that continuously "does something" with
 * messaging between various actors.
 *
 * The implementation is based on the following take on the problem:
 * http://www.dalnefre.com/wp/2010/08/dining-philosophers-in-humus
 */

print("===-----------------------------------------------------===")
print("|            Dining Philosophers Sample App               |")
print("|                                                         |")
print("| USAGE: swift run Swift Distributed ActorsSampleDiningPhilosophers [dist] |")
print("===-----------------------------------------------------===")

switch CommandLine.arguments.dropFirst().first {
case "dist":
    try DistributedDiningPhilosophers().run(for: .seconds(10))
default:
    try DiningPhilosophers().run(for: .seconds(10))
}
