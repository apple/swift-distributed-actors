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

final class MembershipGossipLogicTests: ClusteredActorSystemsXCTestCase {
    override func configureActorSystem(settings: inout ActorSystemSettings) {
        settings.cluster.enabled = false // not actually clustering, just need a few nodes
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/replicator/gossip",
            "/system/replicator",
            "/system/swim",
            "/system/clusterEvents",
            "/system/cluster",
            "/system/leadership",
        ]
    }

    lazy var systemA: ActorSystem! = nil
    lazy var systemB: ActorSystem! = nil
    lazy var systemC: ActorSystem! = nil
    var systems: [ActorSystem] = []
    var nodes: [UniqueNode] = []
    var allPeers: [AddressableActorRef] = []

    lazy var a: AddressableActorRef = self.allPeers.first { $0.address.node?.node.systemName == "A" }!
    lazy var b: AddressableActorRef = self.allPeers.first { $0.address.node?.node.systemName == "B" }!
    lazy var c: AddressableActorRef = self.allPeers.first { $0.address.node?.node.systemName == "C" }!

    lazy var testKit: ActorTestKit! = nil

    lazy var pA: ActorTestProbe<Cluster.Gossip>! = nil
    lazy var logicA: MembershipGossipLogic! = nil

    lazy var pB: ActorTestProbe<Cluster.Gossip>! = nil
    lazy var logicB: MembershipGossipLogic! = nil

    lazy var pC: ActorTestProbe<Cluster.Gossip>! = nil
    lazy var logicC: MembershipGossipLogic! = nil

    var logics: [MembershipGossipLogic] {
        [self.logicA, self.logicB, self.logicC]
    }

    var gossips: [Cluster.Gossip] {
        self.logics.map { $0.latestGossip }
    }

    override func setUp() {
        super.setUp()
        self.systemA = setUpNode("A") { settings in
            settings.cluster.enabled = true // to allow remote resolves, though we never send messages there
        }
        self.systemB = setUpNode("B")
        self.systemC = setUpNode("C")

        self.systems = [systemA, systemB, systemC]
        self.nodes = systems.map { $0.cluster.node }
        self.allPeers = try! systems.map { system -> ActorRef<GossipShell<Cluster.Gossip, Cluster.Gossip>.Message> in
            let ref: ActorRef<GossipShell<Cluster.Gossip, Cluster.Gossip>.Message> = try system.spawn("peer", .receiveMessage { _ in .same })
            return self.systemA._resolveKnownRemote(ref, onRemoteSystem: system)
        }.map { $0.asAddressable() }

        self.testKit = self.testKit(self.systemA)

        self.pA = testKit.spawnTestProbe(expecting: Cluster.Gossip.self)
        self.pB = testKit.spawnTestProbe(expecting: Cluster.Gossip.self)
        self.pC = testKit.spawnTestProbe(expecting: Cluster.Gossip.self)
        initializeLogics()
    }

    private func initializeLogics() {
        self.logicA = makeLogic(self.systemA, self.pA)
        self.logicB = makeLogic(self.systemB, self.pB)
        self.logicC = makeLogic(self.systemC, self.pC)
    }

    private func makeLogic(_ system: ActorSystem, _ probe: ActorTestProbe<Cluster.Gossip>) -> MembershipGossipLogic {
        MembershipGossipLogic(
            GossipLogicContext<Cluster.Gossip, Cluster.Gossip>(
                ownerContext: self.testKit(system).makeFakeContext(),
                gossipIdentifier: StringGossipIdentifier("membership")
            ),
            notifyOnGossipRef: probe.ref
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    func test_pickMostBehindNode() throws {
        let gossip = Cluster.Gossip.parse(
            """
            A.up B.joining C.up
            A: A@5 B@5 C@6
            B: A@5 B@1 C@1
            C: A@5 B@5 C@6
            """,
            owner: systemA.cluster.node, nodes: nodes
        )
        logicA.localGossipUpdate(gossip: gossip)



        let round1 = logicA.selectPeers(peers: self.peers(of: logicA))
        round1.shouldEqual([self.b])
    }

//    func test_eventuallyStopGossiping() throws {
//        let gossip = Cluster.Gossip.parse(
//            """
//            A.up B.joining C.up
//            A: A@5 B@5 C@6
//            B: A@5 B@5 C@6
//            C: A@5 B@5 C@6
//            """,
//            owner: systemA.cluster.node, nodes: nodes
//        )
//        logicA.localGossipUpdate(gossip: gossip)
//
//        var rounds = 0
//        while logicA.sele {
//            pprint("...")
//            rounds += 1
//        }
//
//        rounds.shouldBeLessThanOrEqual(10)
//    }

    func test_logic_peersChanged() throws {
        let all = [a, b, c]
        let known: [AddressableActorRef] = [a]
        let less: [AddressableActorRef] = []
        let more: [AddressableActorRef] = [a, b]

        let res1 = MembershipGossipLogic.peersChanged(known: known, current: less)
        res1!.removed.shouldEqual([a])
        res1!.added.shouldEqual([])

        let res2 = MembershipGossipLogic.peersChanged(known: known, current: more)
        res2!.removed.shouldEqual([])
        res2!.added.shouldEqual([b])

        let res3 = MembershipGossipLogic.peersChanged(known: [], current: all)
        res3!.removed.shouldEqual([])
        res3!.added.shouldEqual([a, b, c])
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Support functions

    func peers(of logic: MembershipGossipLogic) -> [AddressableActorRef] {
        Array(self.allPeers.filter { $0.address.node! != logic.localNode })
    }

    func selectLogic(_ peer: AddressableActorRef) -> MembershipGossipLogic {
        guard let node = peer.address.node else {
            fatalError("MUST have node, was: \(peer.address)")
        }

        switch node.node.systemName {
        case "A": return self.logicA
        case "B": return self.logicB
        case "C": return self.logicC
        default: fatalError("No logic for peer: \(peer)")
        }
    }

    func origin(_ logic: MembershipGossipLogic) -> AddressableActorRef {
        if ObjectIdentifier(logic) == ObjectIdentifier(logicA) {
            return self.a
        } else if ObjectIdentifier(logic) == ObjectIdentifier(logicB) {
            return self.b
        } else if ObjectIdentifier(logic) == ObjectIdentifier(logicC) {
            return self.c
        } else {
            fatalError("No addressable peer for logic: \(logic)")
        }
    }
}

extension MembershipGossipLogic {
    var nodeName: String {
        self.localNode.node.systemName
    }
}