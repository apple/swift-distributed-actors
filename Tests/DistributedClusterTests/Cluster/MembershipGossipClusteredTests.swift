//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import Foundation
import NIOSSL
import XCTest

@testable import DistributedCluster

final class MembershipGossipClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = [
            "/system/cluster"
        ]
        settings.excludeActorPaths = [
            "/system/cluster/swim",  // we assume it works fine
            "/system/receptionist",
        ]
        settings.excludeGrep = [
            "_TimerKey",
            "schedule next gossip",
            "Gossip payload updated",
        ]
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking .down

    func test_down_beGossipedToOtherNodes() async throws {
        let strategy = ClusterSystemSettings.LeadershipSelectionSettings.lowestReachable(minNumberOfMembers: 3)
        let first = await setUpNode("first") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }
        let second = await setUpNode("second") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }
        let third = await setUpNode("third") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        third.cluster.join(endpoint: second.cluster.node.endpoint)

        try assertAssociated(first, withAtLeast: second.cluster.node)
        try assertAssociated(second, withAtLeast: third.cluster.node)
        try assertAssociated(first, withAtLeast: third.cluster.node)

        try await self.assertMemberStatus(on: second, node: first.cluster.node, is: .up, within: .seconds(10))
        try await self.assertMemberStatus(on: second, node: second.cluster.node, is: .up, within: .seconds(10))
        try await self.assertMemberStatus(on: second, node: third.cluster.node, is: .up, within: .seconds(10))

        let firstEvents = await testKit(first).spawnClusterEventStreamTestProbe()
        let secondEvents = await testKit(second).spawnClusterEventStreamTestProbe()
        let thirdEvents = await testKit(third).spawnClusterEventStreamTestProbe()

        second.cluster.down(endpoint: third.cluster.node.endpoint)

        try self.assertMemberDown(firstEvents, node: third.cluster.node)
        try self.assertMemberDown(secondEvents, node: third.cluster.node)
        try self.assertMemberDown(thirdEvents, node: third.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM + joining

    func test_join_swimDiscovered_thirdNode() async throws {
        let first = await setUpNode("first") { settings in
            settings.endpoint.port = 7111
        }
        let second = await setUpNode("second") { settings in
            settings.endpoint.port = 8222
        }
        let third = await setUpNode("third") { settings in
            settings.endpoint.port = 9333
        }

        // 1. first join second
        first.cluster.join(endpoint: second.cluster.node.endpoint)

        // 2. third join second
        third.cluster.join(endpoint: second.cluster.node.endpoint)

        // confirm 1
        try assertAssociated(first, withAtLeast: second.cluster.node)
        try assertAssociated(second, withAtLeast: first.cluster.node)
        pinfo("Associated: first <~> second")
        // confirm 2
        try assertAssociated(third, withAtLeast: second.cluster.node)
        try assertAssociated(second, withAtLeast: third.cluster.node)
        pinfo("Associated: second <~> third")

        // 3.1. first should discover third
        // confirm 3.1
        try assertAssociated(first, withAtLeast: third.cluster.node)
        pinfo("Associated: first ~> third")

        // 3.2. third should discover first
        // confirm 3.2
        try assertAssociated(third, withAtLeast: first.cluster.node)
        pinfo("Associated: third ~> first")

        // excellent, all nodes know each other
        pinfo("Associated: third <~> first")
    }
}
