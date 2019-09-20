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
    func test_gossip_down_node_shouldReachAllNodes() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster.swim.gossip.probeInterval = .milliseconds(100)
        }
        let second = self.setUpNode("second") { settings in
            settings.cluster.swim.gossip.probeInterval = .milliseconds(100)
        }
        let third = self.setUpNode("third") { settings in
            settings.cluster.swim.gossip.probeInterval = .milliseconds(100)
        }

        let nodeToBeDowned = third.cluster.node

        let testKit = ActorTestKit(first)

        first.cluster.join(node: second.cluster.node.node)
        second.cluster.join(node: third.cluster.node.node)
        // third and second should join up via SWIM gossip discovery:
        try assertAssociated(first, withAtLeast: nodeToBeDowned)

        first.cluster.down(node: nodeToBeDowned)

        // this information should reach the remote node via gossip
        try testKit.eventually(within: .seconds(3), interval: .milliseconds(150)) {
            try self.assertMemberStatus(on: third, node: third.cluster.node, is: .down)

            try self.assertMemberStatus(on: first, node: third.cluster.node, is: .down)
            try self.assertMemberStatus(on: second, node: third.cluster.node, is: .down)
        }
    }

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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: leader decision: .joining -> .up

    // TODO: more tests about leadership here? I.e. 4 nodes, then remove one; etc
    override var captureLogs: Bool {
        return false
    }

    func test_joining_to_up_decisionByLeader() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)

            try assertAssociated(first, withAtLeast: second.cluster.node)
            try assertAssociated(second, withAtLeast: third.cluster.node)
            try assertAssociated(first, withAtLeast: third.cluster.node)

            try self.testKit(first).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: first, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: first, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: first, node: third.cluster.node, is: .up)

                try self.assertMemberStatus(on: second, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: third.cluster.node, is: .up)

                try self.assertMemberStatus(on: third, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: third, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: third, node: third.cluster.node, is: .up)
            }
        }
    }
}
