//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster

import ArgumentParser

@main
struct ClusterDBoot: AsyncParsableCommand {
  @Option(name: .shortAndLong, help: "The port to bind the cluster daemon on.")
  var port: Int = ClusterDaemon.defaultEndpoint.port

  @Option(help: "The host address to bid the cluster daemon on.")
  var host: String = ClusterDaemon.defaultEndpoint.host

  mutating func run() async throws {
    let daemon = await ClusterSystem.startClusterDaemon(configuredWith: self.configure)

    #if DEBUG
    daemon.system.log.warning("RUNNING ClusterD DEBUG binary, operation is likely to be negatively affected. Please build/run the ClusterD process using '-c release' configuration!")
    #endif

    try await daemon.system.park()
  }

  func configure(_ settings: inout ClusterSystemSettings) {
    // other nodes will be discovering us, not the opposite
    settings.discovery = .init(static: [])

    settings.endpoint = Cluster.Endpoint(
      systemName: "clusterd",
      host: host,
      port: port)
  }
}