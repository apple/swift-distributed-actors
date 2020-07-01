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

final class ClusterMembershipSnapshotTests: ClusteredActorSystemsXCTestCase {
    func test_membershipSnapshot_initialShouldContainSelfNode() {
        let system = self.setUpNode("first")

        system.cluster.membershipSnapshot.members(atLeast: .joining).shouldContain(
            Cluster.Member(node: system.cluster.uniqueNode, status: .joining)
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

            let nodes: [UniqueNode] = snapshot.members(atMost: .up).map { $0.uniqueNode }
            nodes.shouldContain(first.cluster.uniqueNode)
            nodes.shouldContain(second.cluster.uniqueNode)
            nodes.shouldContain(third.cluster.uniqueNode)
        }
    }

    func test_membershipSnapshot_beInSyncWithEvents() throws {
        let first = self.setUpNode("first")
        let second = self.setUpNode("second")
        let third = self.setUpNode("third")

        let events = self.testKit(first).spawnEventStreamTestProbe(subscribedTo: first.cluster.events)

        try self.joinNodes(node: first, with: second)
        try self.joinNodes(node: first, with: third)
        try self.joinNodes(node: second, with: third)

        var membership: Cluster.Membership = .empty
        while let event = try events.maybeExpectMessage(within: .seconds(1)) {
            let snapshot: Cluster.Membership = first.cluster.membershipSnapshot
            try membership.apply(event: event)

            // snapshot MUST NOT be "behind" it may be HEAD though (e.g. 3 events are being emitted now, and we'll get them in order)
            // but the snapshot already knows about all of them.
            snapshot.count.shouldBeGreaterThanOrEqual(membership.count)
            membership.members(atLeast: .joining).forEach { mm in
                if let nm = snapshot.uniqueMember(mm.uniqueNode) {
                    nm.status.shouldBeGreaterThanOrEqual(mm.status)
                }
            }
        }
    }
}
