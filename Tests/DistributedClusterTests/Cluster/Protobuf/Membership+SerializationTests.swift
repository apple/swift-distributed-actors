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
import Foundation  // for pretty printing JSON
import Logging
import NIO
import XCTest

@testable import DistributedCluster

final class MembershipSerializationTests: SingleClusterSystemXCTestCase {
    lazy var context: Serialization.Context! = Serialization.Context(
        log: system.log,
        system: system,
        allocator: system.settings.serialization.allocator
    )

    override func tearDown() async throws {
        try await super.tearDown()
        self.context = nil
    }

    func test_serializationOf_membership() throws {
        let membership: Cluster.Membership = [
            Cluster.Member(
                node: Cluster.Node(
                    endpoint: Cluster.Endpoint(systemName: "first", host: "1.1.1.1", port: 7337),
                    nid: .random()
                ),
                status: .up
            ),
            Cluster.Member(
                node: Cluster.Node(
                    endpoint: Cluster.Endpoint(systemName: "second", host: "2.2.2.2", port: 8228),
                    nid: .random()
                ),
                status: .down
            ),
        ]

        let proto = try membership.toProto(context: self.context)
        let back = try Cluster.Membership(fromProto: proto, context: self.context)

        back.shouldEqual(membership)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Measuring serialization sizes

    func test_gossip_serialization() throws {
        let members = (1...15).map { id in
            Cluster.Member(
                node: Cluster.Node(
                    endpoint: Cluster.Endpoint(systemName: "\(id)", host: "1.1.1.\(id)", port: 1111),
                    nid: .init(UInt64("\(id)\(id)\(id)\(id)")!)  // pretend a real-ish looking ID, but be easier to read
                ),
                status: .up
            )
        }
        let nodes = members.map(\.node)

        let gossip = Cluster.MembershipGossip.parse(
            """
            1.joining 2.joining 3.joining 4.up 5.up 6.up 7.up 8.up 9.down 10.down 11.up 12.up 13.up 14.up 15.up  
            1: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            2: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            3: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            4: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            5: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            6: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            7: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            8: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            9: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            10: 1:4 2:4 3:4 4:6 5:7 6:7 7:8 8:8 9:12 10:12 11:8 12:8 13:8 14:9 15:6
            """,
            owner: nodes.first!,
            nodes: nodes
        )

        let serialized = try system.serialization.serialize(gossip)

        pnote("\(serialized.buffer.readData().stringDebugDescription())")
        pinfo("Serialized size: \(serialized.buffer.count) bytes")
        pinfo("  Manifest.serializerID: \(serialized.manifest.serializerID)")
        pinfo("  Manifest.hint:         \(optional: serialized.manifest.hint)")

        serialized.manifest.serializerID.shouldEqual(Serialization.SerializerID._ProtobufRepresentable)
        serialized.buffer.count.shouldEqual(2105)

        let back = try system.serialization.deserialize(as: Cluster.MembershipGossip.self, from: serialized)
        "\(pretty: back)".shouldStartWith(prefix: "\(pretty: gossip)")  // nicer human readable error
        back.shouldEqual(gossip)  // the actual soundness check
    }
}
