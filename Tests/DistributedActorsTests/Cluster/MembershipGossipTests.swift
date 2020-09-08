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
    var nodeA: UniqueNode!
    var nodeB: UniqueNode!
    var nodeC: UniqueNode!
    var fourthNode: UniqueNode!
    lazy var allNodes = [
        self.nodeA!, self.nodeB!, self.nodeC!, self.fourthNode!,
    ]

    override func setUp() {
        super.setUp()
        self.nodeA = UniqueNode(protocol: "sact", systemName: "firstA", host: "127.0.0.1", port: 7111, nid: .random())
        self.nodeB = UniqueNode(protocol: "sact", systemName: "secondB", host: "127.0.0.1", port: 7222, nid: .random())
        self.nodeC = UniqueNode(protocol: "sact", systemName: "thirdC", host: "127.0.0.1", port: 7333, nid: .random())
        self.fourthNode = UniqueNode(protocol: "sact", systemName: "fourthD", host: "127.0.0.1", port: 7444, nid: .random())
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Merging gossips

    func test_mergeForward_incomingGossip_firstGossipFromOtherNode() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.joining
            A: A:1
            """, owner: self.nodeA, nodes: self.allNodes
        )

        let incoming = Cluster.MembershipGossip.parse(
            """
            B.joining
            B: B:1
            """, owner: self.nodeB, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incoming)

        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(node: self.nodeB, previousStatus: nil, toStatus: .joining)]
        )

        gossip.shouldEqual(
            Cluster.MembershipGossip.parse(
                """
                A.joining B.joining
                A: A:1 B:1
                B: B:1
                """, owner: self.nodeA, nodes: self.allNodes
            )
        )
    }

    func test_mergeForward_incomingGossip_firstGossipFromOtherNodes() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.joining
            A: A:1
            """, owner: self.nodeA, nodes: self.allNodes
        )

        let incoming = Cluster.MembershipGossip.parse(
            """
            B.joining C.joining
            B: B:1 C:1
            C: B:1 C:1
            """, owner: self.nodeB, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incoming)

        Set(directive.effectiveChanges).shouldEqual(
            Set(
                [
                    Cluster.MembershipChange(node: self.nodeB, previousStatus: nil, toStatus: .joining),
                    Cluster.MembershipChange(node: self.nodeC, previousStatus: nil, toStatus: .joining),
                ]
            )
        )

        let expected = Cluster.MembershipGossip.parse(
            """
            A.joining B.joining C.joining
            A: A:1 B:1 C:1
            B: B:1 C:1
            C: B:1 C:1
            """, owner: self.nodeA, nodes: self.allNodes
        )

        gossip.seen.shouldEqual(expected.seen)
        gossip.seen.version(at: self.nodeA).shouldEqual(expected.seen.version(at: self.nodeA))
        gossip.seen.version(at: self.nodeB).shouldEqual(expected.seen.version(at: self.nodeB))
        gossip.seen.version(at: self.nodeC).shouldEqual(expected.seen.version(at: self.nodeC))
        gossip.membership.shouldEqual(expected.membership)
        gossip.shouldEqual(expected)
    }

    func test_mergeForward_incomingGossip_sameVersions() {
        var gossip = Cluster.MembershipGossip(ownerNode: self.nodeA)
        _ = gossip.membership.join(self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeA) // v: myself:1, second:1
        _ = gossip.membership.join(self.nodeB) // myself:joining, second:joining

        let gossipFromSecond = Cluster.MembershipGossip(ownerNode: self.nodeB)
        let directive = gossip.mergeForward(incoming: gossipFromSecond)

        directive.effectiveChanges.shouldEqual([])
    }

    func test_mergeForward_incomingGossip_fromFourth_onlyKnowsAboutItself() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.joining B.joining B.joining
            A: A@1 B@1 C@1
            """, owner: self.nodeA, nodes: self.allNodes
        )

        // only knows about fourth, while myGossip has first, second and third
        let incomingGossip = Cluster.MembershipGossip.parse(
            """
            D.joining
            D: D@1
            """, owner: self.fourthNode, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incomingGossip)

        // this test also covers so <none> does not accidentally cause changes into .removed, which would be catastrophic
        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(node: self.fourthNode, previousStatus: nil, toStatus: .joining)]
        )
        gossip.shouldEqual(
            Cluster.MembershipGossip.parse(
                """
                A.joining B.joining C.joining
                A: A@1 B@1 C@1 D@1
                D: D@1
                """, owner: self.nodeA, nodes: self.allNodes
            )
        )
    }

    func test_mergeForward_incomingGossip_localHasRemoved_incomingHasOldViewWithDownNode() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.down C.up
            A: A@5 B@5 C@6 
            B: A@5 B@5 C@6
            C: A@5 B@5 C@6
            """,
            owner: self.nodeA, nodes: self.allNodes
        )

        // while we just removed it:
        gossip.converged().shouldBeTrue() // sanity check
        let removedMember: Cluster.Member = gossip.membership.uniqueMember(self.nodeB)!
        _ = gossip.pruneMember(removedMember)
        gossip.incrementOwnerVersion()

        let incomingOldGossip = Cluster.MembershipGossip.parse(
            """
            A.up B.down C.up
            A: A@5 B@5  C@6
            B: A@5 B@10 C@6
            C: A@5 B@5  C@6
            """,
            owner: self.nodeB, nodes: self.allNodes
        ) // TODO: this will be rejected since owner is the downe node (!) add another test with third sending the same info

        let gossipBeforeMerge = gossip
        let directive = gossip.mergeForward(incoming: incomingOldGossip)

        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [] // no effect
        )

        gossip.membership.members(atLeast: .joining).shouldNotContain(removedMember)
        gossip.seen.nodes.shouldNotContain(removedMember.uniqueNode)

        gossip.seen.shouldEqual(gossipBeforeMerge.seen)
        gossip.membership.shouldEqual(gossipBeforeMerge.membership)
    }

    func test_mergeForward_incomingGossip_concurrent_leaderDisagreement() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.joining [leader:A]
            A: A@5 B@5 
            B: A@5 B@5
            """,
            owner: self.nodeA, nodes: self.allNodes
        )

        // this may happen after healing a cluster partition,
        // once the nodes talk to each other again, they will run leader election and resolve the double leader situation
        // until that happens, the two leaders indeed remain as-is -- as the membership itself is not the right place to resolve
        // who shall be leader
        let incomingGossip = Cluster.MembershipGossip.parse(
            """
            A.up B.joining C.up [leader:B]
            B: B@2 C@1
            C: B@5 C@9
            """,
            owner: self.nodeC, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incomingGossip)

        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [
                // such unknown -> up may indeed happen, if we have a large cluster, which ends up partitioned into two
                // each side keeps adding new nodes, and then the partition heals. The core membership does NOT prevent this,
                // what WOULD prevent this is how the leaders are selected -- e.g. dynamic quorum etc. Though even quorums can be cheated
                // in dramatic situations (e.g. we add more nodes on one side than quorum, so it gets "its illegal quorum"),
                // such is the case with any "dynamic" quorum however. We CAN and will provide strategies to select leaders which
                // strongly militate such risk though.
                Cluster.MembershipChange(node: self.nodeC, previousStatus: nil, toStatus: .up),
                // note that this has NO effect on the leader; we keep trusting "our" leader,
                // leader election should kick in and reconcile those two
            ]
        )

        let expected = Cluster.MembershipGossip.parse(
            """
            A.up B.joining C.up [leader:A]
            A: A:5 B:5 C:9
            B: A:5 B:5 C@1
            C:     B:5 C:9
            """, owner: self.nodeA, nodes: self.allNodes
        )

        gossip.seen.shouldEqual(expected.seen)
        gossip.membership.shouldEqual(expected.membership)
        gossip.shouldEqual(expected)
    }

    func test_mergeForward_incomingGossip_concurrent_simple() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.joining
            A: A@4
            """, owner: self.nodeA, nodes: self.allNodes
        )

        let concurrent = Cluster.MembershipGossip.parse(
            """
            A.joining B.joining
            B: B@2
            """, owner: self.nodeB, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: concurrent)

        gossip.owner.shouldEqual(self.nodeA)
        directive.effectiveChanges.count.shouldEqual(0)
        gossip.shouldEqual(
            Cluster.MembershipGossip.parse(
                """
                A.up B.joining
                A: A@4 B@2
                B: B@2
                """, owner: self.nodeA, nodes: self.allNodes
            )
        )
    }

    func test_mergeForward_incomingGossip_hasNewNode() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up
            A: A@5
            """,
            owner: self.nodeA, nodes: self.allNodes
        )

        var incomingGossip = gossip
        _ = incomingGossip.membership.join(self.nodeB)
        incomingGossip.incrementOwnerVersion()

        let directive = gossip.mergeForward(incoming: incomingGossip)

        directive.causalRelation.shouldEqual(.happenedBefore)
        directive.effectiveChanges.shouldEqual(
            [Cluster.MembershipChange(node: self.nodeB, previousStatus: nil, toStatus: .joining)]
        )

        gossip.membership.members(atLeast: .joining).shouldContain(Cluster.Member(node: self.nodeB, status: .joining))
    }

    func test_mergeForward_removal_incomingGossip_isAhead_hasRemovedNodeKnownToBeDown() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.down C.up [leader:A]
            A: A@5 B@5 C@6
            B: A@5 B@5 C@6
            C: A@5 B@5 C@6
            """,
            owner: self.nodeA, nodes: self.allNodes
        )

        let incomingGossip = Cluster.MembershipGossip.parse(
            """
            A.up C.up
            A: A@5 C@6
            C: A@5 C@7
            """, owner: self.nodeC, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incomingGossip)

        directive.causalRelation.shouldEqual(.concurrent)
        // v-clock wise this indeed is concurrent, however due to down/removal involved, we can handle it

        directive.effectiveChanges.shouldEqual(
            [
                Cluster.MembershipChange(node: self.nodeB, previousStatus: .down, toStatus: .removed),
            ]
        )

        gossip.shouldEqual(
            Cluster.MembershipGossip.parse(
                """
                A.up C.up [leader:A]
                A: A@5 C@7
                C: A@5 C@7
                """, owner: self.nodeA, nodes: self.allNodes
            )
        )
    }

    func test_mergeForward_incomingGossip_removal_isAhead_hasMyNodeRemoved_thusWeKeepItAsRemoved() {
        var gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.down C.up
            A: A@5 B@5 C@6
            B: A@5 B@5 C@6
            C: A@5 B@5 C@6
            """,
            owner: self.nodeB, nodes: self.allNodes
        )

        let incomingGossip = Cluster.MembershipGossip.parse(
            """
            A.up C.up
            A: A@5 C@6
            C: A@5 C@7
            """, owner: self.nodeC, nodes: self.allNodes
        )

        let directive = gossip.mergeForward(incoming: incomingGossip)

        directive.causalRelation.shouldEqual(.concurrent)
        directive.effectiveChanges.shouldEqual(
            [
                Cluster.MembershipChange(node: self.nodeB, previousStatus: .down, toStatus: .removed),
            ]
        )

        // we MIGHT receive a removal of "our node" however we must never apply such change!
        // we know we are `.down` and that's the most "we" will ever perceive ourselves as -- i.e. removed is only for "others".
        let expected = Cluster.MembershipGossip.parse(
            """
            A.up B.removed C.up
            A: A@5 B@5 C@6
            B: A@5 B@5 C@7
            C: A@5 B@5 C@7
            """, owner: self.nodeB, nodes: self.allNodes
        )
        gossip.seen.version(at: self.nodeA).shouldEqual(expected.seen.version(at: self.nodeA))
        gossip.seen.version(at: self.nodeB).shouldEqual(expected.seen.version(at: self.nodeB))
        gossip.seen.version(at: self.nodeC).shouldEqual(expected.seen.version(at: self.nodeC))
        gossip.shouldEqual(expected)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Convergence

    func test_converged_shouldBeTrue_forNoMembers() {
        var gossip = Cluster.MembershipGossip(ownerNode: self.nodeA)
        _ = gossip.membership.join(self.nodeA)
        gossip.converged().shouldBeTrue()

        gossip.incrementOwnerVersion()
        gossip.converged().shouldBeTrue()
    }

    func test_converged_amongUpMembers() {
        var gossip = Cluster.MembershipGossip(ownerNode: self.nodeA)
        _ = gossip.membership.join(self.nodeA)
        _ = gossip.membership.mark(self.nodeA, as: .up)

        _ = gossip.membership.join(self.nodeB)
        _ = gossip.membership.mark(self.nodeB, as: .up)

        _ = gossip.membership.join(self.nodeC)
        _ = gossip.membership.mark(self.nodeC, as: .up)

        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeC)
        // we are "ahead" of others
        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeB)
        // others still catching up
        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeC)
        // second has caught up, but third still not
        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeA)
        // second has caught up, but third catching up
        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeC)
        // second and third have caught up
        gossip.converged().shouldBeTrue()

        // if second and third keep moving on, they still have at-least seen our version,
        // co convergence still should remain true
        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeC)

        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeC)
        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeC)
        gossip.converged().shouldBeTrue()
    }

    func test_converged_othersAreOnlyDown() {
        let gossip = Cluster.MembershipGossip.parse(
            """
            A.up B.down
            A: A@8 B@5 
            B: B@6
            C: A@7 B@5
            """, owner: self.nodeA, nodes: self.allNodes
        )

        // since all other nodes other than A are down or joining, thus we do not count them in convergence
        gossip.converged().shouldBeTrue()
    }

    // FIXME: we should not need .joining nodes to participate on convergence()
    func fixme_converged_joiningOrDownMembersDoNotCount() {
        var gossip = Cluster.MembershipGossip(ownerNode: self.nodeA)
        _ = gossip.membership.join(self.nodeA)

        _ = gossip.membership.join(self.nodeB)
        _ = gossip.membership.mark(self.nodeB, as: .joining)

        _ = gossip.membership.join(self.nodeC)
        _ = gossip.membership.mark(self.nodeC, as: .down)

        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeC)

        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeC)

        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.nodeC, at: self.nodeC)

        // all have caught up, however they are only .down or .joining (!)
        gossip.converged().shouldBeTrue()
        // (convergence among only joining members matters since then we can kick off the leader actions to move members up)

        // joining a node that is up, and caught up though means we can converge
        _ = gossip.membership.join(self.fourthNode)
        _ = gossip.membership.mark(self.fourthNode, as: .up)

        // as the new node is up, it matters to convergence, it should have the full picture but does not
        // as such, we are not converged
        gossip.converged().shouldBeFalse()

        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.nodeA)
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.nodeB)
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.nodeC)
        // it moved a bit fast:
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.fourthNode, at: self.fourthNode)
        // but we're up to date with this:
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.fourthNode)
        gossip.seen.incrementVersion(owner: self.nodeA, at: self.fourthNode)

        // the new node has caught up:
        gossip.converged().shouldBeTrue()
    }

    func test_gossip_eventuallyConverges() {
        func makeRandomGossip(owner node: UniqueNode) -> Cluster.MembershipGossip {
            var gossip = Cluster.MembershipGossip(ownerNode: node)
            _ = gossip.membership.join(node)
            _ = gossip.membership.mark(node, as: .joining)
            var vv = VersionVector()
            vv.state[.uniqueNode(node)] = VersionVector.Version(node.port)
            gossip.seen.underlying[node] = .init(vv)

            // know just enough that we're not alone and thus need to communicate:
            _ = gossip.membership.join(self.nodeA)
            _ = gossip.membership.mark(self.nodeA, as: .up)
            _ = gossip.seen.incrementVersion(owner: self.nodeA, at: self.nodeA)
            _ = gossip.seen.incrementVersion(owner: node, at: self.nodeA)

            _ = gossip.membership.join(self.nodeB)
            _ = gossip.membership.mark(self.nodeB, as: .up)
            _ = gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeB)
            _ = gossip.seen.incrementVersion(owner: self.nodeB, at: self.nodeB)
            _ = gossip.seen.incrementVersion(owner: node, at: self.nodeB)
            _ = gossip.seen.incrementVersion(owner: node, at: self.nodeB)
            return gossip
        }

        let firstGossip = makeRandomGossip(owner: self.nodeA)
        let secondGossip = makeRandomGossip(owner: self.nodeB)
        let thirdGossip = makeRandomGossip(owner: self.nodeC)
        let fourthGossip = makeRandomGossip(owner: self.fourthNode)

        var gossips = [
            1: firstGossip,
            2: secondGossip,
            3: thirdGossip,
            4: fourthGossip,
        ]

        gossips.forEach { _, gossip in
            assert(!gossip.converged(), "Should not start out convergent")
        }

        var gossipSend = 0
        let gossipSendsMax = 100
        while gossipSend < gossipSendsMax {
            let (_, from) = gossips.randomElement()!
            var (toId, target) = gossips.randomElement()!

            _ = target.mergeForward(incoming: from)
            gossips[toId] = target

            if gossips.allSatisfy({ $1.converged() }) {
                break
            }

            gossipSend += 1
        }

        let allConverged = gossips.allSatisfy { $1.converged() }
        guard allConverged else {
            XCTFail("""
            Gossips among \(gossips.count) members did NOT converge after \(gossipSend) (individual) sends.
            \(gossips.values.map { "\($0)" }.joined(separator: "\n"))
            """)
            return
        }

        pinfo("Gossip converged on all \(gossips.count) members, after \(gossipSend) (individual) sends")
    }
}
