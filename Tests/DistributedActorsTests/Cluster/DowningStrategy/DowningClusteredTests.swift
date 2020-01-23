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
import XCTest

// "Get down!"
final class DowningClusteredTests: ClusteredNodesTestBase {
    enum NodeStopMethod {
        case leaveSelf // TODO: eventually this one will be more graceful, ensure others see us leave etc
        case downSelf
        case shutdownSelf
        case downFromSecond
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Downing

    func shared_stoppingSelfNode_shouldPropagateToOtherNodes(stopMethod: NodeStopMethod) throws {
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

        switch stopMethod {
        case .leaveSelf:
            first.cluster.leave()
        case .downSelf:
            first.cluster.down(node: first.cluster.node.node)
        case .shutdownSelf:
            first.shutdown()
        case .downFromSecond:
            second.cluster.down(node: first.cluster.node.node)
        }

        switch stopMethod {
        case .leaveSelf, .downSelf, .downFromSecond:
            _ = try shouldNotThrow {
                try self.testKit(second).eventually(within: .seconds(10)) {
                    try self.capturedLogs(of: first).shouldContain(prefix: "Self node was marked [.down]!", failTest: false)
                }
            }
        case .shutdownSelf:
            () // no extra assertion
        }

        _ = try shouldNotThrow {
            try self.testKit(second).eventually(within: .seconds(20)) {
                // at least one of the nodes will first realize that first is unreachable,
                // upon doing so, the leader election picks a new leader -- it will be `second` on lowest-reachable-address leadership for example.
                // As we now have a leader, downing may perform it's move.\

                try self.capturedLogs(of: second).shouldContain(grep: "@localhost:9001, status: down", failTest: false)
                try self.capturedLogs(of: third).shouldContain(grep: "@localhost:9001, status: down", failTest: false)
            }
        }
    }

    func test_stoppingSelfNode_shouldPropagateToOtherNodes_downedBy_leaveSelf() throws {
        try self.shared_stoppingSelfNode_shouldPropagateToOtherNodes(stopMethod: .leaveSelf)
    }

    func test_stoppingSelfNode_shouldPropagateToOtherNodes_downedBy_downSelf() throws {
        try self.shared_stoppingSelfNode_shouldPropagateToOtherNodes(stopMethod: .downSelf)
    }

    func test_stoppingSelfNode_shouldPropagateToOtherNodes_downedBy_shutdownSelf() throws {
        try self.shared_stoppingSelfNode_shouldPropagateToOtherNodes(stopMethod: .shutdownSelf)
    }

    func test_stoppingSelfNode_shouldPropagateToOtherNodes_downedBy_downFromSecond() throws {
        try self.shared_stoppingSelfNode_shouldPropagateToOtherNodes(stopMethod: .downFromSecond)
    }
}
