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

@main
struct Main {
  static func main() async {
    let system = ActorSystem()

    let greeter: Greeter = Greeter(transport: system)

    try! await greeter.greet(name: "Caplin")
    try! await greeter.greet(name: "Caplin")
    try! await greeter.greet(name: "Caplin")
    try! await greeter.greet(name: "Caplin")
    try! await greeter.greet(name: "Caplin")

    Thread.sleep(.seconds(1))
  }
}