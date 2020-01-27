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

final class ClusterMembershipGossipTests: ClusteredNodesTestBase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = ["/system/cluster"]
        settings.excludeActorPaths = ["/system/cluster/swim"] // we assume it works fine
        settings.excludeGrep = ["with generation"] // exclude timers noise
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
}
