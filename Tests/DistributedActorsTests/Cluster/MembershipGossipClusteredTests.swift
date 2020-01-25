//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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

final class MembershipGossipClusteredTests: ClusteredNodesTestBase {
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

    func test_down_beGossipedToOtherNodes() throws {
        try shouldNotThrow {
            let strategy = ClusterSettings.LeadershipSelectionSettings.lowestReachable(minNumberOfMembers: 3)
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = strategy
                settings.cluster.onDownAction = .none
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = strategy
                settings.cluster.onDownAction = .none
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.autoLeaderElection = strategy
                settings.cluster.onDownAction = .none
            }

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)

            try assertAssociated(first, withAtLeast: second.cluster.node)
            try assertAssociated(second, withAtLeast: third.cluster.node)
            try assertAssociated(first, withAtLeast: third.cluster.node)

            try self.testKit(second).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: second, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: third.cluster.node, is: .up)
            }

            second.cluster.down(node: third.cluster.node.node)

            try self.testKit(first).eventually(within: .seconds(5)) {
                try self.assertMemberStatus(on: first, node: third.cluster.node, is: .down)
            }
            try self.testKit(second).eventually(within: .seconds(5)) {
                try self.assertMemberStatus(on: second, node: third.cluster.node, is: .down)
            }
            try self.testKit(third).eventually(within: .seconds(5)) {
                try self.assertMemberStatus(on: third, node: third.cluster.node, is: .down)
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM + joining

    func test_join_swimDiscovered_thirdNode() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster.node.port = 7111
        }
        let second = self.setUpNode("second") { settings in
            settings.cluster.node.port = 8222
        }
        let third = self.setUpNode("third") { settings in
            settings.cluster.node.port = 9333
        }

        // 1. first join second
        first.cluster.join(node: second.cluster.node.node)

        // 2. third join second
        third.cluster.join(node: second.cluster.node.node)

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

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Pruning (removing) a member once everyone has seen it down

    func test_downingNode_eventuallyResultsInRemovalFromGossip() throws {
        // This action is carefully orchestrated by the leader -- on our case: first
        let (first, second) = self.setUpPair { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = .timeout(.default)
        }
        let third = self.setUpNode("third") { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = .timeout(.default)
        }
        try self.joinNodes(node: first, with: second, ensureMembers: .up)
        try self.joinNodes(node: third, with: second, ensureMembers: .up)

        first.cluster.down(node: second.cluster.node.node)
        first.log.info("LEADER ISSUE DOWN  = \(second.cluster.node)")

        let firstCapturedLogs = self.capturedLogs(of: first)

        _ = try shouldNotThrow {
            let testKit: ActorTestKit = self.testKit(first)

            try testKit.eventually(within: .seconds(20), interval: .seconds(1)) {
                try firstCapturedLogs.shouldContain(
                    grep:
                    "Leader moving member: Cluster.MembershipChange(node: sact://third@localhost:9003, replaced: [nil], fromStatus: joining, toStatus: up)", failTest: false
                )
            }

            try testKit.eventually(within: .seconds(20), interval: .seconds(1)) {
                try firstCapturedLogs.shouldContain(
                    grep:
                    "Leader removing member: Member(sact://second@localhost:9002, status: down, reachability: reachable)", failTest: false
                )
            }

            Thread.sleep(.seconds(5))

            firstCapturedLogs.logs.filter { log in
                "\(log)".contains("Leader removing member")
            }.count.shouldEqual(1)
        }
    }
}
