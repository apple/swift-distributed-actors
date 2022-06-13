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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIOSSL
import XCTest

final class MembershipGossipClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = [
            "/system/cluster",
        ]
        settings.excludeActorPaths = [
            "/system/cluster/swim", // we assume it works fine
            "/system/receptionist",
        ]
        settings.excludeGrep = [
            "TimerKey",
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

        first.cluster.join(node: second.cluster.uniqueNode.node)
        third.cluster.join(node: second.cluster.uniqueNode.node)

        try assertAssociated(first, withAtLeast: second.cluster.uniqueNode)
        try assertAssociated(second, withAtLeast: third.cluster.uniqueNode)
        try assertAssociated(first, withAtLeast: third.cluster.uniqueNode)

        try await self.testKit(second).eventually(within: .seconds(10)) {
            try await self.assertMemberStatus(on: second, node: first.cluster.uniqueNode, is: .up)
            try await self.assertMemberStatus(on: second, node: second.cluster.uniqueNode, is: .up)
            try await self.assertMemberStatus(on: second, node: third.cluster.uniqueNode, is: .up)
        }

        let firstEvents = testKit(first).spawnEventStreamTestProbe(subscribedTo: first.cluster.events)
        let secondEvents = testKit(second).spawnEventStreamTestProbe(subscribedTo: second.cluster.events)
        let thirdEvents = testKit(third).spawnEventStreamTestProbe(subscribedTo: third.cluster.events)

        second.cluster.down(node: third.cluster.uniqueNode.node)

        try self.assertMemberDown(firstEvents, node: third.cluster.uniqueNode)
        try self.assertMemberDown(secondEvents, node: third.cluster.uniqueNode)
        try self.assertMemberDown(thirdEvents, node: third.cluster.uniqueNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM + joining

    func test_join_swimDiscovered_thirdNode() async throws {
        let first = await setUpNode("first") { settings in
            settings.node.port = 7111
        }
        let second = await setUpNode("second") { settings in
            settings.node.port = 8222
        }
        let third = await setUpNode("third") { settings in
            settings.node.port = 9333
        }

        // 1. first join second
        first.cluster.join(node: second.cluster.uniqueNode.node)

        // 2. third join second
        third.cluster.join(node: second.cluster.uniqueNode.node)

        // confirm 1
        try assertAssociated(first, withAtLeast: second.cluster.uniqueNode)
        try assertAssociated(second, withAtLeast: first.cluster.uniqueNode)
        pinfo("Associated: first <~> second")
        // confirm 2
        try assertAssociated(third, withAtLeast: second.cluster.uniqueNode)
        try assertAssociated(second, withAtLeast: third.cluster.uniqueNode)
        pinfo("Associated: second <~> third")

        // 3.1. first should discover third
        // confirm 3.1
        try assertAssociated(first, withAtLeast: third.cluster.uniqueNode)
        pinfo("Associated: first ~> third")

        // 3.2. third should discover first
        // confirm 3.2
        try assertAssociated(third, withAtLeast: first.cluster.uniqueNode)
        pinfo("Associated: third ~> first")

        // excellent, all nodes know each other
        pinfo("Associated: third <~> first")
    }
}
