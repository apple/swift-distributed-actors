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
@testable import DistributedCluster
import Logging
import NIO
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
final class ClusterEventsSerializationTests {

    let testCase: SingleClusterSystemTestCase
    
    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    @Test
    func test_serializationOf_membershipChange() throws {
        let change = Cluster.MembershipChange(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "first", host: "1.1.1.1", port: 7337), nid: .random()), previousStatus: .leaving, toStatus: .removed)
        let event = Cluster.Event.membershipChange(change)
        
        let context = self.testCase.context
        let proto = try event.toProto(context: context)
        let back = try Cluster.Event(fromProto: proto, context: context)
        
        back.shouldEqual(event)
    }

    @Test
    func test_serializationOf_leadershipChange() throws {
        let old = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "first", host: "1.1.1.1", port: 7337), nid: .random()), status: .joining)
        let new = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "first", host: "1.2.2.1", port: 2222), nid: .random()), status: .up)
        let event = Cluster.Event.leadershipChange(Cluster.LeadershipChange(oldLeader: old, newLeader: new)!) // !-safe, since new/old leader known to be different
        
        let context = self.testCase.context
        let proto = try event.toProto(context: context)
        let back = try Cluster.Event(fromProto: proto, context: context)
        
        back.shouldEqual(event)
    }
}
