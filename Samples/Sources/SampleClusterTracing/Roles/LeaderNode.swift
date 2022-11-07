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

struct LeaderNode {
    let system: ClusterSystem

    init(name: String, port: Int) async {
        self.system = await ClusterSystem(name) { settings in
            settings.bindPort = port

            // We are purposefully making very slow calls, so they show up nicely in tracing:
            settings.remoteCall.defaultTimeout = .seconds(20)
        }
    }

    func run() async throws {
        monitorMembership(on: self.system)

        let cook = await PrimaryCook(actorSystem: system)
        let meal = try await cook.makeDinner()

        self.system.log.notice("Made dinner successfully!")
    }
}
