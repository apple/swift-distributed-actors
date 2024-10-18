//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import DistributedCluster
import Testing

@Suite(.serialized)
final class ClusterMembershipSnapshotTests: ClusteredActorSystemsXCTestCase {
    
    @Test
    func test_membershipSnapshot_initialShouldContainSelfNode() async throws {
        let system = await setUpNode("first")

        let testKit: ActorTestKit = self.testKit(system)
        try await testKit.eventually(within: .seconds(5)) {
            await system.cluster.membershipSnapshot.members(atLeast: .joining).shouldContain(
                Cluster.Member(node: system.cluster.node, status: .joining)
            )
        }
    }

    @Test
    func test_membershipSnapshot_shouldBeUpdated() async throws {
        let (first, second) = await self.setUpPair()
        try await self.joinNodes(node: first, with: second)

        let third = await setUpNode("third")
        try await self.joinNodes(node: first, with: third)

        let testKit: ActorTestKit = self.testKit(first)
        try await testKit.eventually(within: .seconds(5)) {
            let snapshot: Cluster.Membership = await first.cluster.membershipSnapshot

            // either joining or up is fine, though we want to see that they're not in down or worse states
            guard (snapshot.count(withStatus: .joining) + snapshot.count(withStatus: .up)) == 3 else {
                throw testKit.error(line: #line - 1)
            }

            let nodes: [Cluster.Node] = snapshot.members(atMost: .up).map(\.node)
            nodes.shouldContain(first.cluster.node)
            nodes.shouldContain(second.cluster.node)
            nodes.shouldContain(third.cluster.node)
        }
    }

    @Test
    func test_membershipSnapshot_beInSyncWithEvents() async throws {
        let first = await setUpNode("first")
        let second = await setUpNode("second")
        let third = await setUpNode("third")

        let events = await self.testKit(first).spawnClusterEventStreamTestProbe()

        try await self.joinNodes(node: first, with: second)
        try await self.joinNodes(node: first, with: third)
        try await self.joinNodes(node: second, with: third)

        var membership: Cluster.Membership = .empty
        while let event = try events.maybeExpectMessage(within: .seconds(1)) {
            let snapshot: Cluster.Membership = await first.cluster.membershipSnapshot
            try membership.apply(event: event)

            // snapshot MUST NOT be "behind" it may be HEAD though (e.g. 3 events are being emitted now, and we'll get them in order)
            // but the snapshot already knows about all of them.
            snapshot.count.shouldBeGreaterThanOrEqual(membership.count)
            membership.members(atLeast: .joining).forEach { mm in
                if let nm = snapshot.member(mm.node) {
                    nm.status.shouldBeGreaterThanOrEqual(mm.status)
                }
            }
        }
    }
}
