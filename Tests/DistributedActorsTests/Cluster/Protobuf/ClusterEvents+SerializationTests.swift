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
import Logging
import NIO
import XCTest

final class ClusterEventsSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    lazy var context: ActorSerializationContext! = ActorSerializationContext(log: system.log, localNode: system.cluster.node, system: system, allocator: system.settings.serialization.allocator)

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.context = nil
    }

    func test_serializationOf_membershipChange() throws {
        let change = MembershipChange(node: UniqueNode(node: Node(systemName: "first", host: "1.1.1.1", port: 7337), nid: .random()), fromStatus: .leaving, toStatus: .removed)
        let event = ClusterEvent.membershipChange(change)

        let proto = try event.toProto(context: self.context)
        let back = try ClusterEvent(fromProto: proto, context: context)

        back.shouldEqual(event)
    }

    func test_serializationOf_leadershipChange() throws {
        let old = Member(node: UniqueNode(node: Node(systemName: "first", host: "1.1.1.1", port: 7337), nid: .random()), status: .joining)
        let new = Member(node: UniqueNode(node: Node(systemName: "first", host: "1.2.2.1", port: 2222), nid: .random()), status: .up)
        let event = ClusterEvent.leadershipChange(LeadershipChange(oldLeader: old, newLeader: new)!) // !-safe, since new/old leader known to be different

        let proto = try event.toProto(context: self.context)
        let back = try ClusterEvent(fromProto: proto, context: context)

        back.shouldEqual(event)
    }
}
