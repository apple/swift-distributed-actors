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
    var firstNode: UniqueNode!
    var secondNode: UniqueNode!
    var thirdNode: UniqueNode!
    var fourthNode: UniqueNode!

    var gossip: Cluster.Gossip!

    override func setUp() {
        super.setUp()
        self.firstNode = UniqueNode(protocol: "sact", systemName: "myself", host: "127.0.0.1", port: 7111, nid: .random())
        self.secondNode = UniqueNode(protocol: "sact", systemName: "second", host: "127.0.0.1", port: 7222, nid: .random())
        self.thirdNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7333, nid: .random())
        self.fourthNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7444, nid: .random())

        self.gossip = Cluster.Gossip(ownerNode: self.firstNode)
        _ = self.gossip.membership.join(self.firstNode)
    }

    func test_mergeForward_incomingGossip_firstGossipFromOtherNode() {
        var gossipFromSecond = Cluster.Gossip(ownerNode: self.secondNode)
        _ = gossipFromSecond.membership.join(self.secondNode)

        let directive = self.gossip.mergeForward(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(member: Cluster.Member(node: self.secondNode, status: .joining), toStatus: .joining)]
        )
    }

    func test_mergeForward_incomingGossip_sameVersions() {
        self.gossip.seen.incrementVersion(owner: self.secondNode, at: self.firstNode) // v: myself:1, second:1
        _ = self.gossip.membership.join(self.secondNode) // myself:joining, second:joining

        let gossipFromSecond = Cluster.Gossip(ownerNode: self.secondNode)
        let directive = self.gossip.mergeForward(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual([])
    }

    func test_mergeForward_incomingGossip_hasNoInformation() {
        _ = self.gossip.membership.join(self.firstNode)
        self.gossip.incrementOwnerVersion()
        _ = self.gossip.membership.join(self.secondNode)
        self.gossip.seen.incrementVersion(owner: self.secondNode, at: self.secondNode)
        _ = self.gossip.membership.join(self.thirdNode)
        self.gossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)

        // only knows about fourth, while myGossip has first, second and third
        var incomingGossip = Cluster.Gossip(ownerNode: self.fourthNode)
        _ = incomingGossip.membership.join(self.fourthNode)
        incomingGossip.incrementOwnerVersion()

        let directive = self.gossip.mergeForward(incoming: incomingGossip)

        // this test also covers so <none> does not accidentally cause changes into .removed, which would be catastrophic
        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(member: Cluster.Member(node: self.fourthNode, status: .joining), toStatus: .joining)]
        )
    }

    func test_converged_shouldBeFalse_forNoMembers() {
        var gossip = self.gossip!
        gossip.converged().shouldBeFalse()

        gossip.incrementOwnerVersion()
        gossip.converged().shouldBeFalse()
    }

    func test_converged_amongUpMembers() {
        var gossip = self.gossip!
        _ = gossip.membership.mark(self.firstNode, as: .up)

        _ = gossip.membership.join(self.secondNode)
        _ = gossip.membership.mark(self.secondNode, as: .up)

        _ = gossip.membership.join(self.thirdNode)
        _ = gossip.membership.mark(self.thirdNode, as: .up)

        gossip.seen.incrementVersion(owner: self.firstNode, at: self.firstNode)
        gossip.seen.incrementVersion(owner: self.firstNode, at: self.secondNode)
        gossip.seen.incrementVersion(owner: self.firstNode, at: self.thirdNode)
        // we are "ahead" of others
//        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.secondNode, at: self.firstNode)
        gossip.seen.incrementVersion(owner: self.secondNode, at: self.secondNode)
        // others still catching up
//        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        // second has caught up, but third still not
//        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.firstNode)
        // second has caught up, but third catching up
//        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.secondNode)
        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)
        // second and third have caught up
//        gossip.converged().shouldBeTrue()

        // if second and third keep moving on, they still have at-least seen our version,
        // co convergence still should remain true
        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)

        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        pprint("gossip = \(gossip)")
        gossip.converged().shouldBeTrue()
    }

    func test_converged_joiningOrDownMembersDoNotCount() {
        var gossip = self.gossip!

        _ = gossip.membership.joining(self.secondNode)
        _ = gossip.membership.mark(self.secondNode, as: .joining)

        _ = gossip.membership.join(self.thirdNode)
        _ = gossip.membership.mark(self.thirdNode, as: .down)

        gossip.seen.incrementVersion(owner: self.firstNode, at: self.firstNode)
        gossip.seen.incrementVersion(owner: self.firstNode, at: self.secondNode)
        gossip.seen.incrementVersion(owner: self.firstNode, at: self.thirdNode)

        gossip.seen.incrementVersion(owner: self.secondNode, at: self.firstNode)
        gossip.seen.incrementVersion(owner: self.secondNode, at: self.secondNode)
        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)

        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.firstNode)
        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.secondNode)
        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)

        // all have caught up, however they are only .down or .joining (!)
        gossip.converged().shouldBeFalse()

        // joining a node that is up, and caught up though means we can converge
        _ = gossip.membership.join(self.fourthNode)
        _ = gossip.membership.mark(self.fourthNode, as: .up)

        // if second and third keep moving on, they still have at-least seen our version,
        // co convergence still should remain true
        gossip.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode)

        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        gossip.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        gossip.converged().shouldBeTrue()
    }
}
