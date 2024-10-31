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
import Foundation
import NIOSSL
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct MembershipGossipClusteredTests {
    let testCase: ClusteredActorSystemsTestCase

    init() throws {
        self.testCase = try ClusteredActorSystemsTestCase()
        self.self.testCase.configureLogCapture = { settings in
            settings.filterActorPaths = [
                "/system/cluster",
            ]
            settings.excludeActorPaths = [
                "/system/cluster/swim", // we assume it works fine
                "/system/receptionist",
            ]
            settings.excludeGrep = [
                "_TimerKey",
                "schedule next gossip",
                "Gossip payload updated",
            ]
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking .down
    @Test
    func test_down_beGossipedToOtherNodes() async throws {
        let strategy = ClusterSystemSettings.LeadershipSelectionSettings.lowestReachable(minNumberOfMembers: 3)
        let first = await self.testCase.setUpNode("first") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }
        let second = await self.testCase.setUpNode("second") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }
        let third = await self.testCase.setUpNode("third") { settings in
            settings.autoLeaderElection = strategy
            settings.onDownAction = .none
        }

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        third.cluster.join(endpoint: second.cluster.node.endpoint)

        try self.testCase.assertAssociated(first, withAtLeast: second.cluster.node)
        try self.testCase.assertAssociated(second, withAtLeast: third.cluster.node)
        try self.testCase.assertAssociated(first, withAtLeast: third.cluster.node)

        try await self.testCase.assertMemberStatus(on: second, node: first.cluster.node, is: .up, within: .seconds(10))
        try await self.testCase.assertMemberStatus(on: second, node: second.cluster.node, is: .up, within: .seconds(10))
        try await self.testCase.assertMemberStatus(on: second, node: third.cluster.node, is: .up, within: .seconds(10))

        let firstEvents = await self.testCase.testKit(first).spawnClusterEventStreamTestProbe()
        let secondEvents = await self.testCase.testKit(second).spawnClusterEventStreamTestProbe()
        let thirdEvents = await self.testCase.testKit(third).spawnClusterEventStreamTestProbe()

        second.cluster.down(endpoint: third.cluster.node.endpoint)

        try self.testCase.assertMemberDown(firstEvents, node: third.cluster.node)
        try self.testCase.assertMemberDown(secondEvents, node: third.cluster.node)
        try self.testCase.assertMemberDown(thirdEvents, node: third.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM + joining
    @Test
    func test_join_swimDiscovered_thirdNode() async throws {
        let first = await self.testCase.setUpNode("first") { settings in
            settings.endpoint.port = 7111
        }
        let second = await self.testCase.setUpNode("second") { settings in
            settings.endpoint.port = 8222
        }
        let third = await self.testCase.setUpNode("third") { settings in
            settings.endpoint.port = 9333
        }

        // 1. first join second
        first.cluster.join(endpoint: second.cluster.node.endpoint)

        // 2. third join second
        third.cluster.join(endpoint: second.cluster.node.endpoint)

        // confirm 1
        try self.testCase.assertAssociated(first, withAtLeast: second.cluster.node)
        try self.testCase.assertAssociated(second, withAtLeast: first.cluster.node)
        pinfo("Associated: first <~> second")
        // confirm 2
        try self.testCase.assertAssociated(third, withAtLeast: second.cluster.node)
        try self.testCase.assertAssociated(second, withAtLeast: third.cluster.node)
        pinfo("Associated: second <~> third")

        // 3.1. first should discover third
        // confirm 3.1
        try self.testCase.assertAssociated(first, withAtLeast: third.cluster.node)
        pinfo("Associated: first ~> third")

        // 3.2. third should discover first
        // confirm 3.2
        try self.testCase.assertAssociated(third, withAtLeast: first.cluster.node)
        pinfo("Associated: third ~> first")

        // excellent, all nodes know each other
        pinfo("Associated: third <~> first")
    }
}
