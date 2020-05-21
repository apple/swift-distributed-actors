//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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
import XCTest

final class CRDTGossipReplicationTests: ClusteredNodesTestBase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/transport.client",
            "/system/transport.server",
            "/system/cluster/gossip",
            "/system/cluster/leadership",
            "/system/cluster",
            "/system/clusterEvents",
            "/system/receptionist",
        ]
    }

    override func configureActorSystem(settings: inout ActorSystemSettings) {
        settings.serialization.register(CRDT.ORSet<String>.self)
    }

    enum OwnsSetMessage: NonTransportableActorMessage {
        case insert(String, CRDT.OperationConsistency)
    }

    func ownsSet(p: ActorTestProbe<CRDT.ORSet<String>>?) -> Behavior<OwnsSetMessage> {
        .setup { context in
            let set: CRDT.ActorOwned<CRDT.ORSet<String>> = CRDT.ORSet.makeOwned(by: context, id: "set")
            set.onUpdate { _, value in
                p?.ref.tell(value)
            }

            return .receiveMessage {
                switch $0 {
                case .insert(let value, let consistency):
                    _ = set.insert(value, writeConsistency: consistency, timeout: .effectivelyInfinite)
                }
                return .same
            }
        }
    }

    func ownsCounter(p: ActorTestProbe<CRDT.GCounter>?) -> Behavior<Int> {
        .setup { context in
            let counter: CRDT.ActorOwned<CRDT.GCounter> = CRDT.GCounter.makeOwned(by: context, id: "counter")
            counter.onUpdate { _, value in
                p?.ref.tell(value)
            }

            return .receiveMessage { value in
                _ = counter.increment(by: value, writeConsistency: .local, timeout: .effectivelyInfinite)
                return .same
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local only direct writes, end up on other nodes via gossip

    func test_gossip_localUpdate_toOtherNode() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first")
            let second = self.setUpNode("second")
            try self.joinNodes(node: first, with: second, ensureMembers: .up)

            let p1 = self.testKit(first).spawnTestProbe("probe-one", expecting: CRDT.ORSet<String>.self)
            let p2 = self.testKit(second).spawnTestProbe("probe-two", expecting: CRDT.ORSet<String>.self)

            let one = try first.spawn("one", ownsSet(p: p1))
            let two = try second.spawn("two", ownsSet(p: p2))

            one.tell(.insert("a", .local))
            one.tell(.insert("aa", .local))

            try expectSet(probe: p1, expected: ["a", "aa"])
            try expectSet(probe: p2, expected: ["a", "aa"])

            two.tell(.insert("b", .local))

            try expectSet(probe: p1, expected: ["a", "aa", "b"])
            try expectSet(probe: p2, expected: ["a", "aa", "b"])
        }
    }

    func test_gossip_readAll_gossipedOwnerAlwaysIncludesAddress() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first")
            let second = self.setUpNode("second")
            let third = self.setUpNode("third")
            let fourth = self.setUpNode("fourth")

            try self.joinNodes(node: first, with: second, ensureMembers: .up)
            try self.joinNodes(node: second, with: third, ensureMembers: .up)
            try self.joinNodes(node: third, with: fourth, ensureMembers: .up)
            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node, fourth.cluster.node)

            let one = try first.spawn("one", ownsCounter(p: nil))
            let two = try second.spawn("two", ownsCounter(p: nil))
            let three = try third.spawn("three", ownsCounter(p: nil))
            let four = try fourth.spawn("four", ownsCounter(p: nil))

            one.tell(1)
            two.tell(2)
            three.tell(3)
            four.tell(4)

            let testKit = self.testKit(first)
            let p = testKit.spawnTestProbe(expecting: CRDT.Replicator.LocalCommand.ReadResult.self)

            // asserting that a read sees all the individual writes, and that they all have "proper" replica IDs
            try testKit.eventually(within: .seconds(10)) {
                first.replicator.tell(.localCommand(.read(CRDT.Identity("counter"), consistency: .all, timeout: .effectivelyInfinite, replyTo: p.ref)))
                switch try p.maybeExpectMessage(within: .seconds(3)) {
                case nil:
                    throw p.error("No message")
                case .some(let .success(data as CRDT.GCounter)):
                    pprint("Performed read form replicas: \(data.prettyDescription)")

                    // each of the owners has a row
                    data.state.count.shouldEqual(4)

                    // each of the rows is owned by an actor; each must have the full address in there
                    for replicaID in data.state.keys {
                        switch replicaID.storage {
                        case .actorAddress(let address):
                            address.node.shouldNotBeNil()
                        default:
                            throw testKit.fail("Unexpected replicaID which was not an actor address: \(replicaID)")
                        }
                    }
                case .some(let other):
                    throw p.error("Unexpected result \(other)")
                }
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Gossip stop conditions

//    override var alwaysPrintCaptureLogs: Bool {
//        true
//    }

    func test_gossip_shouldEventuallyStopSpreading() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first")
            let second = self.setUpNode("second")
            let third = self.setUpNode("third")

            try self.joinNodes(node: first, with: second, ensureMembers: .up)
            try self.joinNodes(node: second, with: third, ensureMembers: .up)
            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node)

            let one = try first.spawn("one", ownsCounter(p: nil))
            let two = try second.spawn("two", ownsCounter(p: nil))
            let three = try third.spawn("three", ownsCounter(p: nil))

            one.tell(1)
            two.tell(2)
            three.tell(3)

            let testKit: ActorTestKit = self.testKit(first)
            guard let firstLogs = self._logCaptures.first else {
                throw testKit.error("Can't get log capture")
            }

            try testKit.assertHolds(for: .seconds(10), interval: .seconds(1)) {
                let logs = firstLogs.grep("Received gossip")
                pinfo("LOGS: \(lineByLine: logs)")

                guard logs.count < 5 else {
                    throw testKit.error("Received gossip more times than expected! Logs: \(lineByLine: logs)")
                }
            }
        }
    }

    private func expectSet(probe: ActorTestProbe<CRDT.ORSet<String>>, expected: Set<String>, file: StaticString = #file, line: UInt = #line) throws {
        let testKit: ActorTestKit = self._testKits.first!

        try testKit.eventually(within: .seconds(10)) {
            let replicated: CRDT.ORSet<String> = try probe.expectMessage(within: .seconds(10), file: file, line: line)
            pinfo("\(probe.name) owned value, updated to: \(replicated)")

            guard expected == replicated.elements else {
                throw testKit.error("Expected: \(expected) but got \(replicated)", file: file, line: line)
            }
        }
    }
}
