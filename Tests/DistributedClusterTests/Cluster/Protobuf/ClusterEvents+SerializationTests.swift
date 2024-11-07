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

import DistributedActorsTestKit
import Logging
import NIO
import XCTest

@testable import DistributedCluster

final class ClusterEventsSerializationTests: SingleClusterSystemXCTestCase {
    lazy var context: Serialization.Context! = Serialization.Context(
        log: system.log,
        system: system,
        allocator: system.settings.serialization.allocator
    )

    func test_serializationOf_membershipChange() throws {
        let change = Cluster.MembershipChange(
            node: Cluster.Node(
                endpoint: Cluster.Endpoint(systemName: "first", host: "1.1.1.1", port: 7337),
                nid: .random()
            ),
            previousStatus: .leaving,
            toStatus: .removed
        )
        let event = Cluster.Event.membershipChange(change)

        let proto = try event.toProto(context: self.context)
        let back = try Cluster.Event(fromProto: proto, context: self.context)

        back.shouldEqual(event)
    }

    func test_serializationOf_leadershipChange() throws {
        let old = Cluster.Member(
            node: Cluster.Node(
                endpoint: Cluster.Endpoint(systemName: "first", host: "1.1.1.1", port: 7337),
                nid: .random()
            ),
            status: .joining
        )
        let new = Cluster.Member(
            node: Cluster.Node(
                endpoint: Cluster.Endpoint(systemName: "first", host: "1.2.2.1", port: 2222),
                nid: .random()
            ),
            status: .up
        )
        let event = Cluster.Event.leadershipChange(Cluster.LeadershipChange(oldLeader: old, newLeader: new)!)  // !-safe, since new/old leader known to be different

        let proto = try event.toProto(context: self.context)
        let back = try Cluster.Event(fromProto: proto, context: self.context)

        back.shouldEqual(event)
    }
}
