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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit
import NIOSSL

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
            try self.assertMemberStatus(testKit, on: third, member: third, is: .down)

            try self.assertMemberStatus(testKit, on: first, member: third, is: .down)
            try self.assertMemberStatus(testKit, on: second, member: third, is: .down)
        }

        self.pinfoAllMemberships(testKit: testKit)
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

        defer {
            if self.testRun?.failureCount ?? 1 > 0 {
                self.printCapturedLogs(first)
                self.printCapturedLogs(second)
                self.printCapturedLogs(third)
            }
        }

        // 1. first join second
        first.cluster.join(node: second.cluster.node.node)
        
        // 2. third join second
        third.cluster.join(node: second.cluster.node.node)

        // confirm 1
        try assertAssociated(first, withAtLeast: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withAtLeast: first.settings.cluster.uniqueBindNode)
        pinfo("Associated: first <~> second")
        // confirm 2
        try assertAssociated(third, withAtLeast: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withAtLeast: third.settings.cluster.uniqueBindNode)
        pinfo("Associated: second <~> third")
        
        // 3.1. first should discover third
        // confirm 3.1
        try assertAssociated(first, withAtLeast: third.settings.cluster.uniqueBindNode)
        pinfo("Associated: first ~> third")
        
        // 3.2. third should discover first
        // confirm 3.2
        try assertAssociated(third, withAtLeast: first.settings.cluster.uniqueBindNode)
        pinfo("Associated: third ~> first")
        
        // excellent, all nodes know each other
        pinfo("Associated: third <~> first")
    }

}
