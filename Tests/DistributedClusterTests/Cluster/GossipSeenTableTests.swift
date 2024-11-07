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
import NIO
import XCTest

@testable import DistributedCluster

/// Tests of just the datatype
final class GossipSeenTableTests: XCTestCase {
    typealias SeenTable = Cluster.MembershipGossip.SeenTable

    var nodeA: Cluster.Node!
    var nodeB: Cluster.Node!
    var nodeC: Cluster.Node!

    lazy var allNodes = [
        self.nodeA!, self.nodeB!, self.nodeC!,
    ]

    override func setUp() {
        super.setUp()
        self.nodeA = Cluster.Node(systemName: "firstA", host: "127.0.0.1", port: 7111, nid: .random())
        self.nodeB = Cluster.Node(systemName: "secondB", host: "127.0.0.1", port: 7222, nid: .random())
        self.nodeC = Cluster.Node(systemName: "thirdC", host: "127.0.0.1", port: 7333, nid: .random())
    }

    func test_seenTable_compare_concurrent_eachOtherDontKnown() {
        let table = Cluster.MembershipGossip.SeenTable.parse(
            """
            A: A@1
            """,
            nodes: self.allNodes
        )

        let incoming = Cluster.MembershipGossip.SeenTable.parse(
            """
            B: B@1
            """,
            nodes: self.allNodes
        )

        // neither node knew about each other, so the updates were concurrent;
        table.compareVersion(observedOn: self.nodeA, to: incoming.version(at: self.nodeB)!)
            .shouldEqual(VersionVector.CausalRelation.concurrent)

        incoming.compareVersion(observedOn: self.nodeB, to: table.version(at: self.nodeA)!)
            .shouldEqual(VersionVector.CausalRelation.concurrent)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increments

    func test_incrementVersion() {
        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("", nodes: self.allNodes))

        table.incrementVersion(owner: self.nodeA, at: self.nodeA)
        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1", nodes: self.allNodes))

        table.incrementVersion(owner: self.nodeA, at: self.nodeA)
        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:2", nodes: self.allNodes))

        table.incrementVersion(owner: self.nodeA, at: self.nodeB)
        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:2 B:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldBeNil()

        table.incrementVersion(owner: self.nodeB, at: self.nodeB)
        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:2 B:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("B:1", nodes: self.allNodes))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: merge

    func test_seenTable_merge_notYetSeenInformation() {
        var table = Cluster.MembershipGossip.SeenTable.parse(
            """
            A: A:1
            """,
            nodes: self.allNodes
        )

        let incoming = Cluster.MembershipGossip.SeenTable.parse(
            """
            B: B:2
            """,
            nodes: self.allNodes
        )

        table.merge(selfOwner: self.nodeA, incoming: incoming)

        table.version(at: self.nodeA)
            .shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
        table.version(at: self.nodeB)
            .shouldEqual(VersionVector.parse("B:2", nodes: self.allNodes))
    }

    func test_seenTable_merge_sameInformation() {
        // a situation in which the two nodes have converged, so their versions are .same

        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.incrementVersion(owner: self.nodeA, at: self.nodeA)  // A observed: A:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:2

        var incoming = Cluster.MembershipGossip(ownerNode: self.nodeB)  // B observed:
        incoming.incrementOwnerVersion()  // B observed: B:1
        incoming.incrementOwnerVersion()  // B observed: B:2
        incoming.seen.incrementVersion(owner: self.nodeB, at: self.nodeA)  // B observed: A:1 B:2

        table.merge(selfOwner: self.nodeA, incoming: incoming.seen)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
    }

    func test_seenTable_merge_aheadInformation() {
        // the incoming gossip is "ahead" and has some more information

        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.incrementVersion(owner: self.nodeA, at: self.nodeA)  // A observed: A:1

        var incoming = Cluster.MembershipGossip(ownerNode: self.nodeB)  // B observed:
        incoming.incrementOwnerVersion()  // B observed: B:1
        incoming.incrementOwnerVersion()  // B observed: B:2
        incoming.seen.incrementVersion(owner: self.nodeB, at: self.nodeA)  // B observed: A:1 B:2

        table.merge(selfOwner: self.nodeA, incoming: incoming.seen)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
    }

    func test_seenTable_merge_behindInformation() {
        // the incoming gossip is "behind"

        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.incrementVersion(owner: self.nodeA, at: self.nodeA)  // A observed: A:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:2

        var incoming = Cluster.MembershipGossip(ownerNode: self.nodeB)  // B observed:
        incoming.incrementOwnerVersion()  // B observed: B:1
        incoming.incrementOwnerVersion()  // B observed: B:2

        table.merge(selfOwner: self.nodeA, incoming: incoming.seen)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1 B:2", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("B:2", nodes: self.allNodes))
    }

    func test_seenTable_merge_concurrentInformation() {
        // the incoming gossip is "concurrent"

        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.incrementVersion(owner: self.nodeA, at: self.nodeA)  // A observed: A:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:1
        table.incrementVersion(owner: self.nodeA, at: self.nodeB)  // A observed: A:1 B:2
        table.incrementVersion(owner: self.nodeA, at: self.nodeC)  // A observed: A:1 B:2 C:1
        // M has seen gossip from S, when it was at t=2
        table.incrementVersion(owner: self.nodeB, at: self.nodeB)  // B observed: B:2
        table.incrementVersion(owner: self.nodeB, at: self.nodeB)  // B observed: B:3

        // in reality S is quite more far ahead, already at t=4
        var incoming = Cluster.MembershipGossip(ownerNode: self.nodeB)  // B observed
        incoming.incrementOwnerVersion()  // B observed: B:1
        incoming.incrementOwnerVersion()  // B observed: B:2
        incoming.incrementOwnerVersion()  // B observed: B:3
        incoming.seen.incrementVersion(owner: self.nodeB, at: self.nodeC)  // B observed: B:3 C:1

        table.merge(selfOwner: self.nodeA, incoming: incoming.seen)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1 B:3 C:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(incoming.seen.version(at: self.nodeB))
    }

    func test_seenTable_merge_concurrentInformation_unknownMember() {
        // the incoming gossip is "concurrent", and has a table entry for a node we don't know

        var table = Cluster.MembershipGossip.SeenTable.parse(
            """
            A: A:4
            """,
            nodes: self.allNodes
        )

        let incoming = Cluster.MembershipGossip.SeenTable.parse(
            """
            A: A:1
            B: B:2 C:1
            C: C:1
            """,
            nodes: self.allNodes
        )

        table.merge(selfOwner: self.nodeA, incoming: incoming)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:4 B:2 C:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("B:2 C:1", nodes: self.allNodes))
        table.version(at: self.nodeC).shouldEqual(VersionVector.parse("C:1", nodes: self.allNodes))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Prune

    func test_prune_removeNodeFromSeenTable() {
        var table = Cluster.MembershipGossip.SeenTable(myselfNode: self.nodeA, version: .init())
        table.incrementVersion(owner: self.nodeA, at: self.nodeA)
        table.incrementVersion(owner: self.nodeA, at: self.nodeC)

        table.incrementVersion(owner: self.nodeB, at: self.nodeC)
        table.incrementVersion(owner: self.nodeB, at: self.nodeB)
        table.incrementVersion(owner: self.nodeB, at: self.nodeA)

        table.incrementVersion(owner: self.nodeC, at: self.nodeC)
        table.incrementVersion(owner: self.nodeC, at: self.nodeA)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1 C:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("B:1 A:1 C:1", nodes: self.allNodes))
        table.version(at: self.nodeC).shouldEqual(VersionVector.parse("C:1 A:1", nodes: self.allNodes))

        table.prune(self.nodeC)

        table.version(at: self.nodeA).shouldEqual(VersionVector.parse("A:1", nodes: self.allNodes))
        table.version(at: self.nodeB).shouldEqual(VersionVector.parse("B:1 A:1", nodes: self.allNodes))
        table.version(at: self.nodeC).shouldBeNil()
    }
}
