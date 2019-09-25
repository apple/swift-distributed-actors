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

final class MembershipSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    lazy var context: ActorSerializationContext! = ActorSerializationContext(log: system.log, localNode: system.cluster.node, system: system, allocator: system.settings.serialization.allocator, traversable: system)

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.context = nil
    }

    func test_serializationOf_membership() throws {
        let membership: Membership = [
            Member(node: UniqueNode(node: Node(systemName: "first", host: "1.1.1.1", port: 7337), nid: .random()), status: .up),
            Member(node: UniqueNode(node: Node(systemName: "second", host: "2.2.2.2", port: 8228), nid: .random()), status: .down),
        ]

        let proto = try membership.toProto(context: self.context)
        let back = try Membership(fromProto: proto, context: context)

        back.shouldEqual(membership)
    }
}
