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

import _PrettyLogHandler
import Distributed
import DistributedCluster
import Logging
import NIO
import OpenTelemetry
import OtlpGRPCSpanExporting
import Tracing

struct ClusterBuilds {
    let system: ClusterSystem
    var workers: [ActorID: BuildWorker] = [:]

    init(name: String, port: Int) async {
        self.system = await ClusterSystem(name) { settings in
            settings.bindPort = port

            settings.plugins.install(plugin: ClusterSingletonPlugin())

            // We are purposefully making allowing long calls:
            settings.remoteCall.defaultTimeout = .seconds(20)

            // Try joining this seed node automatically; once we have joined at least once node, we'll learn about others.
            settings.discovery = ServiceDiscoverySettings(static: [
                Main.Config.seedEndpoint
            ])
        }
        self.system.cluster.join(endpoint: Main.Config.seedEndpoint)
    }

    mutating func run(tasks: Int) async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership

        let buildTasks: [BuildTask] = (0..<tasks).map { _ in BuildTask() }

        // anyone can host the singleton, but by default, it'll be on the build leader (7330) various strategies are possible.
        let ref = try await system.singleton.host(name: BuildLeader.singletonName) { actorSystem in
            return await BuildLeader(buildTasks: buildTasks, actorSystem: actorSystem)
        }

        // all nodes, except the build-leader node contain a few workers:
        if system.isBuildWorker {
            func makeWorker() async {
                let worker = await BuildWorker(actorSystem: self.system)
                workers[worker.id] = worker
            }

            for _ in 0..<Main.Config.workersPerNode {
                await makeWorker()
            }
        }
    }
}