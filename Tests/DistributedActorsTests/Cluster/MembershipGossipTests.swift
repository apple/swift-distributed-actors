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
    var fourthNode: UniqueNode!

    var myGossip: Cluster.Gossip!

    override func setUp() {
        super.setUp()
        self.myselfNode = UniqueNode(protocol: "sact", systemName: "myself", host: "127.0.0.1", port: 7111, nid: .random())
        self.secondNode = UniqueNode(protocol: "sact", systemName: "second", host: "127.0.0.1", port: 7222, nid: .random())
        self.thirdNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7333, nid: .random())
        self.fourthNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7444, nid: .random())
        self.myGossip = Cluster.Gossip(ownerNode: self.myselfNode)
    }

    func test_mergeForward_incomingGossip_firstGossipFromOtherNode() {
        var gossipFromSecond = Cluster.Gossip(ownerNode: self.secondNode)
        _ = gossipFromSecond.membership.join(self.secondNode)

        let directive = self.myGossip.mergeForward(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(member: Cluster.Member(node: self.secondNode, status: .joining), toStatus: .joining)]
        )
    }

    func test_mergeForward_incomingGossip_sameVersions() {
        self.myGossip.seen.incrementVersion(owner: self.secondNode, at: self.myselfNode) // v: myself:1, second:1
        _ = self.myGossip.membership.join(self.secondNode) // myself:joining, second:joining

        let gossipFromSecond = Cluster.Gossip(ownerNode: self.secondNode)
        let directive = self.myGossip.mergeForward(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual([])
    }

    func test_mergeForward_incomingGossip_hasNoInformation() {
        _ = self.myGossip.membership.join(self.myselfNode)
        self.myGossip.incrementOwnerVersion()
        _ = self.myGossip.membership.join(self.secondNode)
        self.myGossip.seen.incrementVersion(owner: self.secondNode, at: self.secondNode)
        _ = self.myGossip.membership.join(self.thirdNode)
        self.myGossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)

        // only knows about fourth, while myGossip has first, second and third
        var incomingGossip = Cluster.Gossip(ownerNode: self.fourthNode)
        _ = incomingGossip.membership.join(self.fourthNode)
        incomingGossip.incrementOwnerVersion()

        let directive = self.myGossip.mergeForward(incoming: incomingGossip)

        // this test also covers so <none> does not accidentally cause changes into .removed, which would be catastrophic
        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(member: Cluster.Member(node: self.fourthNode, status: .joining), toStatus: .joining)]
        )
    }
}
