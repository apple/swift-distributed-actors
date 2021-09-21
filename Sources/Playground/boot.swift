//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-distributed-actors open source project
//
// Copyright (c) 2018 Apple Inc. and the swift-distributed-actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-distributed-actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import Logging
import _Distributed

distributed actor Example {
  lazy var log = Logger(actor: self)

  distributed func hello(name: String) async -> String {
    log.info("Hello, \(name)!")
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = ActorSystem("Playground")
    system.log.info("Started...")

    let example = Example(transport: system)
    let greeting = try! await example.hello(name: "Caplin")
    system.log.info("Greeting from \(example)")

    try! system.park()
  }
}