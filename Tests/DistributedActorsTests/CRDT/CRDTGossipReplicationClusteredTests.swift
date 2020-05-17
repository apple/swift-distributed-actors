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
            "/system/cluster/gossip",
            "/system/cluster/leadership",
            "/system/cluster",
            "/system/clusterEvents",
        ]
    }

    let timeout = TimeAmount.seconds(1)

    func setOwner(p: ActorTestProbe<CRDT.ORSet<String>>) -> Behavior<String> {
        .setup { context in
            let set: CRDT.ActorOwned<CRDT.ORSet<String>> = CRDT.ORSet.makeOwned(by: context, id: "set")
            set.onUpdate { id, value in
                pprint("\(context.myself); id = \(id)")
                p.ref.tell(value)
            }

            return .receiveMessage { message in
                _ = set.insert(message, writeConsistency: .local, timeout: .effectivelyInfinite)
                return .same
            }
        }
    }

    func test_gossip_localUpdate_toOtherNode() throws {
        let first = self.setUpNode("first")
        let second = self.setUpNode("second")

        let p1 = self.testKit(first).spawnTestProbe(expecting: CRDT.ORSet<String>.self)
        let p2 = self.testKit(second).spawnTestProbe(expecting: CRDT.ORSet<String>.self)

        let one = try first.spawn("one", setOwner(p: p1))
        let two = try second.spawn("two", setOwner(p: p2))

        one.tell("a")
        two.tell("b")

        let s1_self = try p1.expectMessage()
        pprint("s1_self = \(s1_self)")
        let s2_self =  try p2.expectMessage()
        pprint("s2_self = \(s2_self)")

        let s2_replicated1 = try p2.expectMessage()
        pprint("s2_replicated 1 = \(s2_replicated1)")

        let s2_replicated2 = try p2.expectMessage()
        pprint("s2_replicated 2 = \(s2_replicated2)")
    }
}