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

import DistributedActors
import DistributedActorsTestKit
import XCTest

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
import NIO
import XCTest

final class ClusterEventStreamTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    let firstMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let secondMember = Member(node: UniqueNode(node: Node(systemName: "System", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)

    override func setUp() {
        self.system = ActorSystem("\(type(of: self))")
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.system = nil
        self.testKit = nil
    }

    func test_clusterEventStream_shouldCollapseEventsAndOfferASnapshotToLateSubscribers() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: ClusterEvent.self)
        let p2 = self.testKit.spawnTestProbe(expecting: ClusterEvent.self)

        let eventStream = try EventStream(
            system,
            name: "ClusterEventStream",
            of: ClusterEvent.self,
            systemStream: false,
            customBehavior: ClusterEventStream.Shell.behavior
        )

        eventStream.subscribe(p1.ref) // sub before first -> up was published
        eventStream.publish(.membershipChange(.init(member: self.firstMember, toStatus: .up)))
        eventStream.subscribe(p2.ref)
        eventStream.publish(.membershipChange(.init(member: self.secondMember, toStatus: .up)))

        // ==== p1 ---------------------

        switch try p1.expectMessage() {
        case .snapshot(.empty):
            () // ok
        default:
            throw p1.error("Expected a snapshot first")
        }
        switch try p1.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.firstMember.node)
        default:
            throw p1.error("Expected a membershipChange")
        }
        switch try p1.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.secondMember.node)
        default:
            throw p1.error("Expected a membershipChange")
        }

        // ==== p2 ---------------------

        switch try p2.expectMessage() {
        case .snapshot(let snapshot):
            snapshot.members(self.firstMember.node.node).shouldEqual([firstMember])
            () // ok
        default:
            throw p2.error("Expected a snapshot first")
        }
        switch try p2.expectMessage() {
        case .membershipChange(let change):
            change.node.shouldEqual(self.secondMember.node)
        default:
            throw p2.error("Expected a membershipChange")
        }
    }

    func test_clusterEventStream_collapseManyEventsIntoSnapshot() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: ClusterEvent.self)

        let eventStream = try EventStream(
            system,
            name: "ClusterEventStream",
            of: ClusterEvent.self,
            systemStream: false,
            customBehavior: ClusterEventStream.Shell.behavior
        )

        eventStream.publish(.membershipChange(.init(member: self.firstMember, toStatus: .joining)))
        eventStream.publish(.membershipChange(.init(member: self.firstMember, toStatus: .up)))
        eventStream.publish(.membershipChange(.init(member: self.secondMember, toStatus: .joining)))
        eventStream.publish(.membershipChange(.init(member: self.secondMember, toStatus: .up)))
        eventStream.subscribe(p1.ref)

        // ==== p1 ---------------------

        switch try p1.expectMessage() {
        case .snapshot(let snapshot):
            let members = snapshot.members(atLeast: .joining)
            Set(members).shouldEqual(Set([firstMember, secondMember]))

        default:
            throw p1.error("Expected a snapshot with all the data")
        }

        try p1.expectNoMessage(for: .milliseconds(100))
    }
}
