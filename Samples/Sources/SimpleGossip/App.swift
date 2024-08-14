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

struct App {

  let port: Int

  init(port: Int) {
    self.port = port
  }

  func run(greeting: String?, for duration: Duration) async throws {
    let system = await ClusterSystem("GossipSystem") { settings in
      settings.endpoint.port = .random(in: 7000...9999)
      settings.discovery = .clusterd
    }
    let peer = await GreetingGossipPeer(actorSystem: system)

    if let greeting {
      try await peer.setGreeting(greeting)
    }

    print("Sleeping...")
    _Thread.sleep(duration)
  }
}


