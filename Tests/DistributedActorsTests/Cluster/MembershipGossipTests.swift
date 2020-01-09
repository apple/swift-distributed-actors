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

/// Tests of just the datatype
final class MembershipGossipTests: XCTestCase {
    var myselfNode: UniqueNode!
    var secondNode: UniqueNode!
    var thirdNode: UniqueNode!

    var myGossip: Membership.Gossip!

    override func setUp() {
        super.setUp()
        self.myselfNode = UniqueNode(protocol: "sact", systemName: "myself", host: "127.0.0.1", port: 7111, nid: .random())
        self.secondNode = UniqueNode(protocol: "sact", systemName: "second", host: "127.0.0.1", port: 7222, nid: .random())
        self.thirdNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7333, nid: .random())
        self.myGossip = Membership.Gossip(ownerNode: self.myselfNode)
    }

    func test_merge_incomingGossip_firstGossipFromOtherNode() {
        let gossipFromSecond = Membership.Gossip(ownerNode: self.secondNode)
        let directive = self.myGossip.merge(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual(
            [MembershipChange(member: Member(node: self.secondNode, status: .joining), toStatus: .joining)]
        )
    }

    func test_merge_incomingGossip_sameVersions() {
        self.myGossip.seen.incrementVersion(owner: self.secondNode, at: self.myselfNode) // v: myself:1, second:1
        _ = self.myGossip.membership.join(self.secondNode) // myself:joining, second:joining

        let gossipFromSecond = Membership.Gossip(ownerNode: self.secondNode)
        let directive = self.myGossip.merge(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual([])
    }
}
