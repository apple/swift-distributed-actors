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
import Logging

struct App {

  init() {}

  func run(greeting: String?, for duration: Duration) async throws {
    let leaderSystem = await ClusterSystem("leader") { settings in
        // ...
    }
    let workerSystem = await ClusterSystem("worker") { settings in
      settings.bindPort = 9999
    }
    let anotherWorkerSystem = await ClusterSystem("worker") { settings in
      settings.bindPort = 9999
    }

    workerSystem.log.warning("Joining...")
    try await leaderSystem.cluster.joined(endpoint: workerSystem.settings.endpoint, within: .seconds(10))
    try await workerSystem.cluster.joined(endpoint: leaderSystem.settings.endpoint, within: .seconds(10))
    workerSystem.log.warning("Joined!")

    var workers: [Worker] = []
    for _ in 0..<9 {
      await workers.append(Worker(actorSystem: workerSystem))
    }
      for _ in 0..<9 {
      await workers.append(Worker(actorSystem: anotherWorkerSystem))
    }

    let LeaderActor = try await Leader(actorSystem: leaderSystem)

    Task {
      try await LeaderActor.work()
    }

    try await leaderSystem.terminated


    print("Sleeping...")
    _Thread.sleep(duration)
  }
}



extension DistributedReception.Key {
  static var workers: DistributedReception.Key<Worker> { "workers" }
}

distributed actor Leader {

  let workerPool: DistributedCluster.WorkerPool<Worker>

  init(actorSystem: ClusterSystem) async throws {
    self.actorSystem = actorSystem
    self.workerPool = try await .init(
      selector: .dynamic(.workers),
      actorSystem: actorSystem
    )
  }

  distributed func work() async throws {
    try? await self.workerPool.submit(work: "my_job")
    try await Task.sleep(for: .seconds(1))
    try await self.work()
  }
}


distributed actor Worker: DistributedWorker {

  lazy var log: Logger = Logger(actor: self)

  init(actorSystem: ClusterSystem) async {
    self.actorSystem = actorSystem
    await actorSystem.receptionist.checkIn(self, with: .workers)
  }

  distributed func submit(work: String) async throws -> String {
    try await Task.sleep(for: .seconds(1))
    log.info("Done \(work)")
    return "Done"
  }
}

