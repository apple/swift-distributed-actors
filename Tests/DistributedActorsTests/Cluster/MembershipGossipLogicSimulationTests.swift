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
import Logging
import NIO
import XCTest

final class MembershipGossipLogicSimulationTests: ClusteredActorSystemsXCTestCase {
    override func configureActorSystem(settings: inout ClusterSystemSettings) {
        settings.cluster.enabled = false // not actually clustering, just need a few nodes
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = [
            "/user/peer",
        ]
    }

    var systems: [ActorSystem] {
        self._nodes
    }

    func system(_ id: String) -> ActorSystem {
        self.systems.first(where: { $0.name == id })!
    }

    var nodes: [UniqueNode] {
        self._nodes.map { $0.cluster.uniqueNode }
    }

    var mockPeers: [AddressableActorRef] = []

    var testKit: ActorTestKit {
        self.testKit(self.systems.first!)
    }

    var logics: [MembershipGossipLogic] = []

    func logic(_ id: String) -> MembershipGossipLogic {
        guard let logic = (self.logics.first { $0.localNode.node.systemName == id }) else {
            fatalError("No such logic for id: \(id)")
        }

        return logic
    }

    var gossips: [Cluster.MembershipGossip] {
        self.logics.map { $0.latestGossip }
    }

    private func makeLogic(_ system: ActorSystem, _ probe: ActorTestProbe<Cluster.MembershipGossip>) -> MembershipGossipLogic {
        MembershipGossipLogic(
            GossipLogicContext<Cluster.MembershipGossip, Cluster.MembershipGossip>(
                ownerContext: self.testKit(system).makeFakeContext(),
                gossipIdentifier: StringGossipIdentifier("membership")
            ),
            notifyOnGossipRef: probe.ref
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Simulation Tests

    func test_avgRounds_untilConvergence() throws {
        let systemA = self.setUpNode("A") { settings in
            settings.cluster.enabled = true
        }
        let systemB = self.setUpNode("B")
        let systemC = self.setUpNode("C")

        let initialGossipState =
            """
            A.up B.joining C.joining
            A: A@3 B@3 C@3
            B: A@3 B@3 C@3
            C: A@3 B@3 C@3
            """

        try self.gossipSimulationTest(
            runs: 10,
            setUpPeers: { () in
                [
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemA.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemB.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemC.cluster.uniqueNode, nodes: self.nodes),
                ]
            },
            updateLogic: { _ in
                let logicA: MembershipGossipLogic = self.logic("A")

                // We simulate that `A` noticed it's the leader and moved `B` and `C` .up
                logicA.receiveLocalGossipUpdate(Cluster.MembershipGossip.parse(
                    """
                    A.up B.up C.up
                    A: A@5 B@3 C@3
                    B: A@3 B@3 C@3
                    C: A@3 B@3 C@3
                    """,
                    owner: systemA.cluster.uniqueNode, nodes: nodes
                ))
            },
            stopRunWhen: { (logics, _) in
                logics.allSatisfy { $0.latestGossip.converged() }
            },
            assert: { results in
                results.roundCounts.max()!.shouldBeLessThanOrEqual(3) // usually 2 but 3 is tolerable; may be 1 if we're very lucky with ordering
                results.messageCounts.max()!.shouldBeLessThanOrEqual(9) // usually 6, but 9 is tolerable
            }
        )
    }

    func test_avgRounds_manyNodes() throws {
        let systemA = self.setUpNode("A") { settings in
            settings.cluster.enabled = true
        }
        let systemB = self.setUpNode("B")
        let systemC = self.setUpNode("C")
        let systemD = self.setUpNode("D")
        let systemE = self.setUpNode("E")
        let systemF = self.setUpNode("F")
        let systemG = self.setUpNode("G")
        let systemH = self.setUpNode("H")
        let systemI = self.setUpNode("I")
        let systemJ = self.setUpNode("J")

        let allSystems = [
            systemA, systemB, systemC, systemD, systemE,
            systemF, systemG, systemH, systemI, systemJ,
        ]

        let initialFewGossip =
            """
            A.up B.joining C.joining D.joining E.joining F.joining G.joining H.joining I.joining J.joining 
            A: A@9 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@5 
            B: A@5 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@5
            C: A@3 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@5
            D: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            E: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            F: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            G: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            H: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            I: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            J: A@2 B@3 C@3 D@5 E@5 F@5 G@5 H@5 I@5 J@1
            """
        let initialNewGossip =
            """
            D.joining E.joining F.joining G.joining H.joining I.joining J.joining 
            D: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            E: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            F: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            G: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            H: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            I: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            J: D@5 E@5 F@5 G@5 H@5 I@5 J@5
            """

        try self.gossipSimulationTest(
            runs: 1,
            setUpPeers: { () in
                [
                    Cluster.MembershipGossip.parse(initialFewGossip, owner: systemA.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialFewGossip, owner: systemB.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialFewGossip, owner: systemC.cluster.uniqueNode, nodes: self.nodes),

                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemD.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemE.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemF.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemG.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemH.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemI.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialNewGossip, owner: systemJ.cluster.uniqueNode, nodes: self.nodes),
                ]
            },
            updateLogic: { _ in
                let logicA: MembershipGossipLogic = self.logic("A")
                let logicD: MembershipGossipLogic = self.logic("D")

                logicA.receiveLocalGossipUpdate(Cluster.MembershipGossip.parse(
                    """
                    A.up B.up C.up D.up E.up F.up G.up H.up I.up J.up 
                    A: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16 
                    B: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    C: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    D: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    E: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    F: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    G: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    H: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    I: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    J: A@20 B@16 C@16 D@16 E@16 F@16 G@16 H@16 I@16 J@16
                    """,
                    owner: systemA.cluster.uniqueNode, nodes: nodes
                ))

                // they're trying to join
                logicD.receiveLocalGossipUpdate(Cluster.MembershipGossip.parse(
                    """
                    A.up B.up C.up D.joining E.joining F.joining G.joining H.joining I.joining J.joining 
                    A: A@11 B@16 C@16 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    B: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    C: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    D: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    E: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    F: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    G: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    H: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    I: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    J: A@12 B@11 C@11 D@9 E@13 F@13 G@13 H@13 I@13 J@13
                    """,
                    owner: systemD.cluster.uniqueNode, nodes: nodes
                ))
            },
            stopRunWhen: { (logics, _) in
                // keep gossiping until all members become .up and converged
                logics.allSatisfy { $0.latestGossip.converged() } &&
                    logics.allSatisfy { $0.latestGossip.membership.count(withStatus: .up) == allSystems.count }
            },
            assert: { results in
                results.roundCounts.max()?.shouldBeLessThanOrEqual(3)
                results.messageCounts.max()?.shouldBeLessThanOrEqual(10)
            }
        )
    }

    func test_shouldEventuallySuspendGossiping() throws {
        let systemA = self.setUpNode("A") { settings in
            settings.cluster.enabled = true
        }
        let systemB = self.setUpNode("B")
        let systemC = self.setUpNode("C")

        let initialGossipState =
            """
            A.up B.joining C.joining
            A: A@3 B@3 C@3
            B: A@3 B@3 C@3
            C: A@3 B@3 C@3
            """

        try self.gossipSimulationTest(
            runs: 10,
            setUpPeers: { () in
                [
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemA.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemB.cluster.uniqueNode, nodes: self.nodes),
                    Cluster.MembershipGossip.parse(initialGossipState, owner: systemC.cluster.uniqueNode, nodes: self.nodes),
                ]
            },
            updateLogic: { _ in
                let logicA: MembershipGossipLogic = self.logic("A")

                // We simulate that `A` noticed it's the leader and moved `B` and `C` .up
                logicA.receiveLocalGossipUpdate(Cluster.MembershipGossip.parse(
                    """
                    A.up B.up C.up
                    A: A@5 B@3 C@3
                    B: A@3 B@3 C@3
                    C: A@3 B@3 C@3
                    """,
                    owner: systemA.cluster.uniqueNode, nodes: nodes
                ))
            },
            stopRunWhen: { logics, _ in
                logics.allSatisfy { logic in
                    logic.selectPeers(self.peers(of: logic)) == [] // no more peers to talk to
                }
            },
            assert: { results in
                results.roundCounts.max()!.shouldBeLessThanOrEqual(4)
                results.messageCounts.max()!.shouldBeLessThanOrEqual(12)
            }
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Simulation test infra

    func gossipSimulationTest(
        runs: Int,
        setUpPeers: () -> [Cluster.MembershipGossip],
        updateLogic: ([MembershipGossipLogic]) -> Void,
        stopRunWhen: ([MembershipGossipLogic], GossipSimulationResults) -> Bool,
        assert: (GossipSimulationResults) -> Void
    ) throws {
        var roundCounts: [Int] = []
        var messageCounts: [Int] = []

        var results = GossipSimulationResults(
            runs: 0,
            roundCounts: roundCounts,
            messageCounts: messageCounts
        )

        let initialGossips = setUpPeers()
        self.mockPeers = try! self.systems.map { system -> _ActorRef<GossipShell<Cluster.MembershipGossip, Cluster.MembershipGossip>.Message> in
            let ref: _ActorRef<GossipShell<Cluster.MembershipGossip, Cluster.MembershipGossip>.Message> =
                try system._spawn("peer", .receiveMessage { _ in .same })
            return self.systems.first!._resolveKnownRemote(ref, onRemoteSystem: system)
        }.map { $0.asAddressable }

        var log = self.systems.first!.log
        log[metadataKey: "actor/path"] = "/user/peer" // mock actor path for log capture

        for _ in 1 ... runs {
            // initialize with user provided gossips
            self.logics = initialGossips.map { initialGossip in
                let system = self.system(initialGossip.owner.node.systemName)
                let probe = self.testKit(system).makeTestProbe(expecting: Cluster.MembershipGossip.self)
                let logic = self.makeLogic(system, probe)
                logic.receiveLocalGossipUpdate(initialGossip)
                return logic
            }

            func allConverged(gossips: [Cluster.MembershipGossip]) -> Bool {
                var allSatisfied = true // on purpose not via .allSatisfy() since we want to print status of each logic
                for g in gossips.sorted(by: { $0.owner.node.systemName < $1.owner.node.systemName }) {
                    let converged = g.converged()
                    let convergenceStatus = converged ? "(locally assumed) converged" : "not converged"

                    log.notice("\(g.owner.node.systemName): \(convergenceStatus)", metadata: [
                        "gossip": Logger.MetadataValue.pretty(g),
                    ])

                    allSatisfied = allSatisfied && converged
                }
                return allSatisfied
            }

            func simulateGossipRound() {
                messageCounts.append(0) // make a counter for this run

                // we shuffle the gossips to simulate the slight timing differences -- not always will the "first" node be the first where the timers trigger
                // and definitely not always will it always _remain_ the first to be gossiping; there may be others still gossiping around spreading their "not super complete"
                // information.
                let participatingGossips = self.logics.shuffled()
                for logic in participatingGossips {
                    let selectedPeers: [AddressableActorRef] = logic.selectPeers(self.peers(of: logic))
                    log.notice("[\(logic.nodeName)] selected peers: \(selectedPeers.map { $0.address.uniqueNode.node.systemName })")

                    for targetPeer in selectedPeers {
                        messageCounts[messageCounts.endIndex - 1] += 1

                        let targetGossip = logic.makePayload(target: targetPeer)
                        if let gossip = targetGossip {
                            log.notice("    \(logic.nodeName) -> \(targetPeer.address.uniqueNode.node.systemName)", metadata: [
                                "gossip": Logger.MetadataValue.pretty(gossip),
                            ])

                            let targetLogic = self.selectLogic(targetPeer)
                            let maybeAck = targetLogic.receiveGossip(gossip, from: self.peer(logic))
                            log.notice("updated [\(targetPeer.address.uniqueNode.node.systemName)]", metadata: [
                                "gossip": Logger.MetadataValue.pretty(targetLogic.latestGossip),
                            ])

                            if let ack = maybeAck {
                                log.notice("    \(logic.nodeName) <- \(targetPeer.address.uniqueNode.node.systemName) (ack)", metadata: [
                                    "ack": Logger.MetadataValue.pretty(ack),
                                ])
                                logic.receiveAcknowledgement(ack, from: self.peer(targetLogic), confirming: gossip)
                            }

                        } else {
                            () // skipping target...
                        }
                    }
                }
            }

            updateLogic(logics)

            var rounds = 0
            log.notice("~~~~~~~~~~~~ new gossip instance ~~~~~~~~~~~~")
            while !stopRunWhen(self.logics, results) {
                rounds += 1
                log.notice("Next gossip round (\(rounds))...")
                simulateGossipRound()

                if rounds > 20 {
                    fatalError("Too many gossip rounds detected! This is definitely wrong.")
                }

                results = .init(
                    runs: runs,
                    roundCounts: roundCounts,
                    messageCounts: messageCounts
                )
            }

            roundCounts += [rounds]
        }

        pinfo("Finished [\(runs)] simulation runs")
        pinfo("    Rounds: \(roundCounts) (\(Double(roundCounts.reduce(0, +)) / Double(runs)) avg)")
        pinfo("  Messages: \(messageCounts) (\(Double(messageCounts.reduce(0, +)) / Double(runs)) avg)")

        assert(results)
    }

    struct GossipSimulationResults {
        let runs: Int
        var roundCounts: [Int]
        var messageCounts: [Int]
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Support functions

    func peers(of logic: MembershipGossipLogic) -> [AddressableActorRef] {
        Array(self.mockPeers.filter { $0.address.uniqueNode != logic.localNode })
    }

    func selectLogic(_ peer: AddressableActorRef) -> MembershipGossipLogic {
        (self.logics.first { $0.localNode == peer.address.uniqueNode })!
    }

    func peer(_ logic: MembershipGossipLogic) -> AddressableActorRef {
        let nodeName = logic.localNode.node.systemName
        if let peer = (self.mockPeers.first { $0.address.uniqueNode.node.systemName == nodeName }) {
            return peer
        } else {
            fatalError("No addressable peer for logic: \(logic), peers: \(self.mockPeers)")
        }
    }
}

private extension MembershipGossipLogic {
    var nodeName: String {
        self.localNode.node.systemName
    }
}
