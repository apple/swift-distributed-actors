//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedCluster
import Logging
import NIO

typealias DefaultDistributedActorSystem = ClusterSystem

@main enum Main {
  static func main() async {
    print("===-----------------------------------------------------===")
    print("|                 Gossip Sample App                       |")
    print("|                                                         |")
    print("| USAGE: swift run SimpleGossip <greeting>?               |")
    print("===-----------------------------------------------------===")

    LoggingSystem.bootstrap(SamplePrettyLogHandler.init)

    let duration = Duration.seconds(60)

    let greeting = CommandLine.arguments.dropFirst().first

    try! await App(port: 0).run(greeting: greeting, for: duration)
  }
}
