//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

let system = ActorSystem()

let greeter: Actor<Greeter> = try! system.spawn("greeter", Greeter.init)

greeter.greet(name: "Caplin")
greeter.greet(name: "Caplin")
greeter.greet(name: "Caplin")
greeter.greet(name: "Caplin")
greeter.greet(name: "Caplin")

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: De-sugared

greeter.ref.tell(.greet(name: "Caplin"))

__sleep(.seconds(1))
