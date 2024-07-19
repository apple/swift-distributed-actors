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

import DistributedCluster

final class SimpleGossip {
    private var forks: [GreetingGossipPeer] = []

    func run(for duration: Duration) async throws {
        let system = await ClusterSystem("GossipSystem") { settings in
//          settings.logging.logLevel = .debug
        }

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1 = await GreetingGossipPeer(actorSystem: system)
        let fork2 = await GreetingGossipPeer(actorSystem: system)
//        let fork3 = await GreetingGossipPeer(actorSystem: system)
//        let fork4 = await GreetingGossipPeer(actorSystem: system)
//        let fork5 = await GreetingGossipPeer(actorSystem: system)
        self.forks = [fork1, fork2,
//                      fork3, fork4, fork5
        ]

      try await fork1.setGreeting("Hello")

      print("Sleeping...")
      _Thread.sleep(duration)

      for p in forks {
        print("Greet: \(p.id)")
        let greeting = try await p.greet(name: "Caplin")
        print("  >>> \(greeting)")
      }
    }
}


