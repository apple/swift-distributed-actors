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
import Tracing

struct ChoppingNode {
    let system: ClusterSystem

    var chopper: VegetableChopper?

    init(name: String, port: Int) async {
        self.system = await ClusterSystem(name) { settings in
            settings.bindPort = port

            // We are purposefully making very slow calls, so they show up nicely in tracing:
            settings.remoteCall.defaultTimeout = .seconds(20)
        }
    }

    mutating func run() async throws {
        monitorMembership(on: self.system)

        let leaderEndpoint = Cluster.Endpoint(host: self.system.cluster.endpoint.host, port: 7330)
        self.system.log.notice("Joining: \(leaderEndpoint)")
        self.system.cluster.join(endpoint: leaderEndpoint)

        try await self.system.cluster.up(within: .seconds(30))
        self.system.log.notice("Joined!")

        let chopper = await VegetableChopper(actorSystem: system)
        self.chopper = chopper
        self.system.log.notice("Vegetable chopper \(chopper) started!")

        for await chopper in await self.system.receptionist.listing(of: VegetableChopper.self) {
            self.system.log.warning("GOT: \(chopper.id)")
        }
    }
}
