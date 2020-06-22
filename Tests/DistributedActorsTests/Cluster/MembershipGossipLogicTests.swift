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
        logicA.localGossipUpdate(payload: gossip)



        let round1 = logicA.selectPeers(peers: self.peers(of: logicA))
        round1.shouldEqual([self.b])
    }

    func test_stopCondition_converged() throws {
        let gossip = Cluster.Gossip.parse(
            """
            A.up B.joining C.up
            A: A@5 B@5 C@6
            B: A@5 B@5 C@6
            C: A@5 B@5 C@6
            """,
            owner: systemA.cluster.node, nodes: nodes
        )
        logicA.localGossipUpdate(payload: gossip)

        let round1 = logicA.selectPeers(peers: self.peers(of: logicA))
        round1.shouldBeEmpty()
    }

    func test_avgRounds_untilConvergence() throws {
        let simulations = 10
        var roundCounts: [Int] = []
        var messageCounts: [Int] = Array(repeating: 0, count: simulations)
        for simulationNr in 1...simulations {
            self.initializeLogics()

            var gossipA = Cluster.Gossip.parse(
                """
                A.up B.up C.up
                A: A@5 B@3 C@3
                B: A@3 B@3 C@3
                C: A@3 B@3 C@3
                """,
                owner: systemA.cluster.node, nodes: nodes
            )
            logicA.localGossipUpdate(payload: gossipA)

            var gossipB = Cluster.Gossip.parse(
                """
                A.up B.joining C.joining
                A: A@3 B@3 C@3
                B: A@3 B@3 C@3
                C: A@3 B@3 C@3
                """,
                owner: systemB.cluster.node, nodes: nodes
            )
            logicB.localGossipUpdate(payload: gossipB)

            var gossipC = Cluster.Gossip.parse(
                """
                A.up B.joining C.joining
                A: A@3 B@3 C@3
                B: A@3 B@3 C@3
                C: A@3 B@3 C@3
                """,
                owner: systemC.cluster.node, nodes: nodes
            )
            logicC.localGossipUpdate(payload: gossipC)

            func allConverged(gossips: [Cluster.Gossip]) -> Bool {
                var allSatisfied = true // on purpose not via .allSatisfy since we want to print status of each logic
                for g in gossips.sorted(by: { $0.owner.node.systemName < $1.owner.node.systemName }) {
                    let converged = g.converged()
                    let convergenceStatus = converged ? "(locally assumed) converged" : "not converged"
                    pinfo("\(g.owner.node.systemName): \(convergenceStatus)")
                    allSatisfied = allSatisfied && converged
                }
                return allSatisfied
            }

            func simulateGossipRound() {
                // we shuffle the gossips to simulate the slight timing differences -- not always will the "first" node be the first where the timers trigger
                // and definitely not always will it always _remain_ the first to be gossiping; there may be others still gossiping around spreading their "not super complete"
                // information.
                let participatingGossips = logics.shuffled()
                for logic in participatingGossips {
                    let selectedPeers: [AddressableActorRef] = logic.selectPeers(peers: self.peers(of: logic))
                    pinfo("[\(logic.nodeName)] selected peers: \(selectedPeers.map({$0.address.node!.node.systemName}))")

                    for targetPeer in selectedPeers {
                        messageCounts[simulationNr - 1] += 1

                        let targetGossip = logic.makePayload(target: targetPeer)
                        if let gossip = targetGossip {
                            // pinfo("    \(logic.nodeName) -> \(targetPeer.address.node!.node.systemName): \(pretty: gossip)")
                            pinfo("    \(logic.nodeName) -> \(targetPeer.address.node!.node.systemName)")

                            let targetLogic = selectLogic(targetPeer)
                            targetLogic.receiveGossip(origin: self.origin(logic), payload: gossip)

                            pinfo("updated [\(targetPeer.address.node!.node.systemName)] gossip: \(targetLogic.latestGossip)")
                            switch targetPeer.address.node!.node.systemName {
                            case "A": gossipA = targetLogic.latestGossip
                            case "B": gossipB = targetLogic.latestGossip
                            case "C": gossipC = targetLogic.latestGossip
                            default: fatalError("No gossip storage space for \(targetPeer)")
                            }
                        } else {
                            () // skipping target...
                        }
                    }
                }
            }

            var rounds = 0
            pnote("~~~~~~~~~~~~ new gossip instance ~~~~~~~~~~~~")
            while !allConverged(gossips: [gossipA, gossipB, gossipC]) {
                rounds += 1
                pnote("Next gossip round (\(rounds))...")
                simulateGossipRound()
            }

            pnote("All peers converged after: [\(rounds) rounds]")
            roundCounts += [rounds]
        }
        pnote("Finished [\(simulations)] simulationsRounds: \(roundCounts)")
        pnote("    Rounds: \(roundCounts) (\(Double(roundCounts.reduce(0, +)) / Double(simulations)) avg)")
        pnote("  Messages: \(messageCounts) (\(Double(messageCounts.reduce(0, +)) / Double(simulations)) avg)")
    }

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