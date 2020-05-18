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

    func ownsSet(p: ActorTestProbe<CRDT.ORSet<String>>) -> Behavior<String> {
        .setup { context in
            let set: CRDT.ActorOwned<CRDT.ORSet<String>> = CRDT.ORSet.makeOwned(by: context, id: "set")
            set.onUpdate { id, value in
                pprint("\(context.myself); id = \(id) <- \(value)")
                p.ref.tell(value)
            }

            return .receiveMessage { message in
                _ = set.insert(message, writeConsistency: .local, timeout: .effectivelyInfinite)
                return .same
            }
        }
    }

    func test_gossip_localUpdate_toOtherNode() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first")
            let second = self.setUpNode("second")
            try self.joinNodes(node: first, with: second, ensureMembers: .up)

            let p1 = self.testKit(first).spawnTestProbe("probe-one", expecting: CRDT.ORSet<String>.self)
            let p2 = self.testKit(second).spawnTestProbe("probe-two", expecting: CRDT.ORSet<String>.self)

            let one = try first.spawn("one", ownsSet(p: p1))
            let two = try second.spawn("two", ownsSet(p: p2))

            one.tell("a")
            one.tell("aa")

            try expectSet(probe: p1, expected: ["a", "aa"])
            try expectSet(probe: p2, expected: ["a", "aa"])

            two.tell("b")

            try expectSet(probe: p1, expected: ["a", "aa", "b"])
            try expectSet(probe: p2, expected: ["a", "aa", "b"])
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