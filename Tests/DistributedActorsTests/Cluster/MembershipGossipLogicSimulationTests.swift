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
import Logging

final class MembershipGossipLogicSimulationTests: ClusteredActorSystemsXCTestCase {
    override func configureActorSystem(settings: inout ActorSystemSettings) {
        settings.cluster.enabled = false // not actually clustering, just need a few nodes
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = [
            "/user/peer"
        ]
    }

    var systems: [ActorSystem] {
        self._nodes
    }
    func system(_ id: String) -> ActorSystem {
        self.systems.first(where: { $0.name == id })!
    }

    var nodes: [UniqueNode] {
        self._nodes.map { $0.cluster.node }
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

    var gossips: [Cluster.Gossip] {
        self.logics.map { $0.latestGossip }
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
                    Cluster.Gossip.parse(initialGossipState, owner: systemA.cluster.node, nodes: self.nodes),
                    Cluster.Gossip.parse(initialGossipState, owner: systemB.cluster.node, nodes: self.nodes),
                    Cluster.Gossip.parse(initialGossipState, owner: systemC.cluster.node, nodes: self.nodes),
                ]
            },
            updateLogic: { logics in
                let logicA: MembershipGossipLogic = self.logic("A")

                // We simulate that `A` noticed it's the leader and moved `B` and `C` .up
                logicA.localGossipUpdate(gossip: Cluster.Gossip.parse(
                    """
                    A.up B.up C.up
                    A: A@5 B@3 C@3
                    B: A@3 B@3 C@3
                    C: A@3 B@3 C@3
                    """,
                    owner: systemA.cluster.node, nodes: nodes
                ))
            },
            stopRunWhen: { (logics, results) in
                logics.allSatisfy { $0.latestGossip.converged() }
            },
            assert: { results in
                results.roundCounts.max()!.shouldBeLessThanOrEqual(3) // usually 2 but 3 is tolerable; may be 1 if we're very lucky with ordering
                results.messageCounts.max()!.shouldBeLessThanOrEqual(9) // usually 6, but 9 is tolerable
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
                    Cluster.Gossip.parse(initialGossipState, owner: systemA.cluster.node, nodes: self.nodes),
                    Cluster.Gossip.parse(initialGossipState, owner: systemB.cluster.node, nodes: self.nodes),
                    Cluster.Gossip.parse(initialGossipState, owner: systemC.cluster.node, nodes: self.nodes),
                ]
            },
            updateLogic: { logics in
                let logicA: MembershipGossipLogic = self.logic("A")

                // We simulate that `A` noticed it's the leader and moved `B` and `C` .up
                logicA.localGossipUpdate(gossip: Cluster.Gossip.parse(
                    """
                    A.up B.up C.up
                    A: A@5 B@3 C@3
                    B: A@3 B@3 C@3
                    C: A@3 B@3 C@3
                    """,
                    owner: systemA.cluster.node, nodes: nodes
                ))
            },
            stopRunWhen: { logics, results in
                logics.allSatisfy { logic in
                    logic.selectPeers(peers: self.peers(of: logic)) == [] // no more peers to talk to
                }
            },
            assert: { results in
                results.roundCounts.max()!.shouldBeLessThanOrEqual(3) // usually 2 but 3 is tolerable; may be 1 if we're very lucky with ordering
                results.messageCounts.max()!.shouldBeLessThanOrEqual(9) // usually 6, but up to 9 is tolerable
            }
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Simulation test infra

    func gossipSimulationTest(
        runs: Int,
        setUpPeers: () -> [Cluster.Gossip],
        updateLogic: ([MembershipGossipLogic]) -> (),
        stopRunWhen: ([MembershipGossipLogic], GossipSimulationResults) -> Bool,
        assert: (GossipSimulationResults) -> ()
    ) throws {
        var roundCounts: [Int] = []
        var messageCounts: [Int] = []

        var results = GossipSimulationResults(
            runs: 0,
            roundCounts: roundCounts,
            messageCounts: messageCounts
        )

        let initialGossips = setUpPeers()
        self.mockPeers = try! self.systems.map { system -> ActorRef<GossipShell<Cluster.Gossip, Cluster.Gossip>.Message> in
            let ref: ActorRef<GossipShell<Cluster.Gossip, Cluster.Gossip>.Message> =
                try system.spawn("peer", .receiveMessage { _ in .same })
            return self.systems.first!._resolveKnownRemote(ref, onRemoteSystem: system)
        }.map { $0.asAddressable() }

        var log = self.systems.first!.log
        log[metadataKey: "actor/path"] = "/user/peer" // mock actor path for log capture

        for runNr in 1...runs {
            // initialize with user provided gossips
            self.logics = initialGossips.map { initialGossip in
                let system = self.system(initialGossip.owner.node.systemName)
                let probe = self.testKit(system).spawnTestProbe(expecting: Cluster.Gossip.self)
                let logic =  self.makeLogic(system, probe)
                logic.localGossipUpdate(gossip: initialGossip)
                return logic
            }

            func allConverged(gossips: [Cluster.Gossip]) -> Bool {
                var allSatisfied = true // on purpose not via .allSatisfy() since we want to print status of each logic
                for g in gossips.sorted(by: { $0.owner.node.systemName < $1.owner.node.systemName }) {
                    let converged = g.converged()
                    let convergenceStatus = converged ? "(locally assumed) converged" : "not converged"

                    log.notice("\(g.owner.node.systemName): \(convergenceStatus)", metadata: [
                        "gossip": Logger.MetadataValue.pretty(g)
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
                    let selectedPeers: [AddressableActorRef] = logic.selectPeers(peers: self.peers(of: logic))
                    log.notice("[\(logic.nodeName)] selected peers: \(selectedPeers.map({$0.address.node!.node.systemName}))")

                    for targetPeer in selectedPeers {
                        messageCounts[messageCounts.endIndex - 1] += 1

                        let targetGossip = logic.makePayload(target: targetPeer)
                        if let gossip = targetGossip {
                            log.notice("    \(logic.nodeName) -> \(targetPeer.address.node!.node.systemName)", metadata: [
                                "gossip": Logger.MetadataValue.pretty(gossip)
                            ])

                            let targetLogic = selectLogic(targetPeer)
                            let maybeAck = targetLogic.receiveGossip(gossip: gossip, from: self.peer(logic))
                            log.notice("updated [\(targetPeer.address.node!.node.systemName)]", metadata: [
                                "gossip": Logger.MetadataValue.pretty(targetLogic.latestGossip)
                            ])

                            if let ack = maybeAck {
                                log.notice("    \(logic.nodeName) <- \(targetPeer.address.node!.node.systemName) (ack)", metadata: [
                                    "ack": Logger.MetadataValue.pretty(ack)
                                ])
                                logic.receiveAcknowledgement(from: self.peer(targetLogic), acknowledgement: ack, confirmsDeliveryOf: gossip)
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

        pinfo("Finished [\(runs)] simulationsRounds: \(roundCounts)")
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
        Array(self.mockPeers.filter { $0.address.node! != logic.localNode })
    }

    func selectLogic(_ peer: AddressableActorRef) -> MembershipGossipLogic {
        guard let uniqueNode = peer.address.node else {
            fatalError("MUST have node, was: \(peer.address)")
        }

        return (self.logics.first { $0.localNode == uniqueNode })!
    }

    func peer(_ logic: MembershipGossipLogic) -> AddressableActorRef {
        let nodeName = logic.localNode.node.systemName
        if let peer = (self.mockPeers.first { $0.address.node?.node.systemName == nodeName }) {
            return peer
        } else {
            fatalError("No addressable peer for logic: \(logic), peers: \(self.mockPeers)")
        }
    }
}