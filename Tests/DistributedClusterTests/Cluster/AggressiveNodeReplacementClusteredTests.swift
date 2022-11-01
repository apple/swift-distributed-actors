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

import DistributedActorsTestKit
@testable import DistributedCluster
import NIO
import XCTest

final class AggressiveNodeReplacementClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/replicator",
            "/system/cluster/swim",
        ]
    }

    func test_join_replacement_repeatedly_shouldConsistentlyReplaceOldNode() async throws {
        let system = await setUpNode("main") { settings in
            settings.bindPort += 100
        }

        let rounds = 5
        for round in 0 ..< rounds {
            print("Round: \(round)")
            system.log.info("Joining second replacement node, round: \(round)")

            // We purposefully make sure the `second` node becomes leader -- it has the lowest port.
            // This is the "worst case" since the leader is the one marking things "down" usually.
            // But here we want to rely on the replacement mechanism triggering the ".down" of the "previous node on
            // the same address".
            let second = await setUpNode("second-\(round)") { settings in
                // always the same host/port (!), this means we'll be continuously replacing the "old" (previous) node
                settings.endpoint.host = system.cluster.endpoint.host
                settings.endpoint.port = system.cluster.endpoint.port - 100 // we want the this node to be the leader -- lowest address
            }

            system.log.notice("Joining [\(second.cluster.endpoint)] to stable main: [\(system.cluster.endpoint)]")

            // Join the main node, and replace the existing "second" node which the main perhaps does not even yet realize has become down.
            // Thus must trigger a down of the old node.
            second.cluster.join(node: system.cluster.node)
            for await actor in await second.receptionist.listing(of: .aggressiveNodeReplacementService).prefix(1) {
                _ = try await actor.randomInt()
                system.log.notice("Roundtrip with second [\(reflecting: second.cluster.node)] - OK")
                break
            }

            try second.shutdown() // shutdown and immediately create a new instance on the same host-port to replace it
            // On purpose: do NOT wait for it to shut down completely.
        }

        let membership: Cluster.Membership = await system.cluster.membershipSnapshot

        // 3 still can happen, since we can have the "down" second and the "joining/up" second.
        membership.count.shouldBeLessThanOrEqual(3)
    }

    distributed actor ServiceActor {
        var hellosSentCount: Int = 0

        init(actorSystem: ActorSystem) async {
            self.actorSystem = actorSystem
            await actorSystem.receptionist.checkIn(self, with: .aggressiveNodeReplacementService)
        }

        distributed func randomInt(in range: Range<Int> = 0 ..< 10) async throws -> Int {
            return Int.random(in: range)
        }
    }
}

extension DistributedReception.Key {
    static var aggressiveNodeReplacementService: DistributedReception.Key<AggressiveNodeReplacementClusteredTests.ServiceActor> {
        "aggressive-rejoin-service-actors"
    }
}
