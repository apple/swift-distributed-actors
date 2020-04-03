//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ClusterMembershipSnapshotTests: ClusteredNodesTestBase {
    func test_membershipSnapshot_initialShouldContainSelfNode() {
        let system = self.setUpNode("first")

        system.cluster.membershipSnapshot.members(atLeast: .joining).shouldContain(
            Cluster.Member(node: system.cluster.node, status: .joining)
        )
    }

    func test_membershipSnapshot_shouldBeUpdated() throws {
        let (first, second) = self.setUpPair()
        try self.joinNodes(node: first, with: second)

        let third = self.setUpNode("third")
        try self.joinNodes(node: first, with: third)

        let testKit: ActorTestKit = self.testKit(first)
        try testKit.eventually(within: .seconds(5)) {
            let snapshot: Cluster.Membership = first.cluster.membershipSnapshot

            // either joining or up is fine, though we want to see that they're not in down or worse states
            guard (snapshot.count(withStatus: .joining) + snapshot.count(withStatus: .up)) == 3 else {
                throw testKit.error(line: #line - 1)
            }

            let nodes: [UniqueNode] = snapshot.members(atMost: .up).map { $0.node }
            nodes.shouldContain(first.cluster.node)
            nodes.shouldContain(second.cluster.node)
            nodes.shouldContain(third.cluster.node)
        }
    }
}
