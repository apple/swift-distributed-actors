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
import NIOSSL
import XCTest

final class ClusterOnDownActionTests: ClusteredActorSystemsXCTestCase {
    func test_onNodeDowned_performShutdown() throws {
        try shouldNotThrow {
            let (first, second) = self.setUpPair { settings in
                settings.cluster.onDownAction = .gracefulShutdown(delay: .milliseconds(300))
            }

            try self.joinNodes(node: first, with: second)

            second.cluster.down(node: first.cluster.node.node)

            try self.capturedLogs(of: first).awaitLogContaining(self.testKit(first), text: "Self node was marked [.down]!")

            try self.testKit(first).eventually(within: .seconds(3)) {
                guard first.isShuttingDown else {
                    throw TestError("System \(first) was not shutting down. It was marked down and the default onDownAction should have triggered!")
                }
            }
        }
    }

    func test_onNodeDowned_configuredNoop_doNothing() throws {
        try shouldNotThrow {
            let (first, second) = self.setUpPair { settings in
                settings.cluster.onDownAction = .none
            }

            try self.joinNodes(node: first, with: second)

            second.cluster.down(node: first.cluster.node.node)

            try self.capturedLogs(of: first).awaitLogContaining(self.testKit(first), text: "Self node was marked [.down]!")

            first.isShuttingDown.shouldBeFalse()
        }
    }
}
