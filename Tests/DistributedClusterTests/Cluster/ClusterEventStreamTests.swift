//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import NIO
import XCTest
import Logging

@testable import DistributedCluster

final class ClusterEventStreamTests: SingleClusterSystemXCTestCase, @unchecked Sendable {
    let memberA = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let memberB = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)

    func test_clusterEventStream_shouldNotCauseDeadLettersOnLocalOnlySystem() throws {
        _ = try self.system._spawn(
            "anything",
            of: String.self,
            .setup { context in
                context.log.info("Hello there!")
                return .stop
            }
        )

        try self.logCapture.awaitLogContaining(self.testKit, text: "Hello there!")
        self.logCapture.grep("Dead letter").shouldBeEmpty()
    }

    func test_clusterEventStream_shouldCollapseEventsAndOfferASnapshotToLateSubscribers() async throws {
        let p1 = self.testKit.makeTestProbe(expecting: Cluster.Event.self)
        let p2 = self.testKit.makeTestProbe(expecting: Cluster.Event.self)

        let eventStream = ClusterEventStream(system, customName: "testClusterEvents")

        await eventStream._subscribe(p1.ref)  // sub before first -> up was published
        await eventStream.publish(.membershipChange(.init(member: self.memberA, toStatus: .up)))
        await eventStream._subscribe(p2.ref)
        await eventStream.publish(.membershipChange(.init(member: self.memberB, toStatus: .up)))

        // ==== p1 ---------------------

        switch try p1.expectMessage() {
        case .snapshot(.empty):
            ()  // ok
        default:
            throw p1.error("Expected a snapshot first")
        }
        switch try p1.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.memberA.node)
        default:
            throw p1.error("Expected a membershipChange")
        }
        switch try p1.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.memberB.node)
        default:
            throw p1.error("Expected a membershipChange")
        }

        // ==== p2 ---------------------

        switch try p2.expectMessage() {
        case .snapshot(let snapshot):
            snapshot.member(self.memberA.node).shouldEqual(self.memberA)
            ()  // ok
        default:
            throw p2.error("Expected a snapshot first")
        }
        switch try p2.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.memberB.node)
        default:
            throw p2.error("Expected a membershipChange")
        }
    }

    func test_clusterEventStream_collapseManyEventsIntoSnapshot() async throws {
        let p1 = self.testKit.makeTestProbe(expecting: Cluster.Event.self)

        let eventStream = ClusterEventStream(system, customName: "testClusterEvents")

        await eventStream.publish(.membershipChange(.init(member: self.memberA, toStatus: .joining)))
        await eventStream.publish(.membershipChange(.init(member: self.memberA, toStatus: .up)))
        await eventStream.publish(.membershipChange(.init(member: self.memberB, toStatus: .joining)))
        await eventStream.publish(.membershipChange(.init(member: self.memberB, toStatus: .up)))
        await eventStream._subscribe(p1.ref)

        // ==== p1 ---------------------

        switch try p1.expectMessage() {
        case .snapshot(let snapshot):
            let members = snapshot.members(atLeast: .joining)
            Set(members).shouldEqual(Set([self.memberA, self.memberB]))

        default:
            throw p1.error("Expected a snapshot with all the data")
        }

        try p1.expectNoMessage(for: .milliseconds(100))
    }

    func test_clusterEventStream_collapseManyEventsIntoSnapshot_async() async throws {
        let eventStream = ClusterEventStream(system, customName: "testClusterEvents")

        // Publish events to change membership
        await eventStream.publish(.membershipChange(.init(member: self.memberA, toStatus: .joining)))
        await eventStream.publish(.membershipChange(.init(member: self.memberA, toStatus: .up)))
        await eventStream.publish(.membershipChange(.init(member: self.memberB, toStatus: .joining)))
        await eventStream.publish(.membershipChange(.init(member: self.memberB, toStatus: .up)))

        // .snapshot is sent on subscribe
        for await event in eventStream {
            switch event {
            case .snapshot(let snapshot):
                let members = snapshot.members(atLeast: .joining)
                Set(members).shouldEqual(Set([self.memberA, self.memberB]))
                return
            default:
                return XCTFail("Expected a snapshot with all the data to be the first received event")
            }
        }
    }
}
