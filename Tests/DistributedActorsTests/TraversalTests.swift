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
//

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIO
import NIOFoundationCompat
import XCTest

final class TraversalTests: ActorSystemXCTestCase {
    struct ActorReady: ActorMessage {
        let name: String
    }

    override func setUp() {
        super.setUp()

        // we use the probe to make sure all actors are started before we start asserting on the tree
        let probe = self.testKit.spawnTestProbe(expecting: ActorReady.self)

        let tellProbeWhenReady: Behavior<Int> = .setup { context in
            probe.tell(ActorReady(name: context.name))
            return .receiveMessage { _ in .same }
        }

        let _: ActorRef<String> = try! self.system.spawn(
            "hello",
            .setup { context in
                probe.tell(ActorReady(name: context.name))
                let _: ActorRef<Int> = try context.spawn("world", tellProbeWhenReady)
                return .receiveMessage { _ in .same }
            }
        )

        let _: ActorRef<String> = try! self.system.spawn(
            "other",
            .setup { context in
                probe.tell(ActorReady(name: context.name))
                let _: ActorRef<Int> = try context.spawn("inner-1", tellProbeWhenReady)
                let _: ActorRef<Int> = try context.spawn("inner-2", tellProbeWhenReady)
                let _: ActorRef<Int> = try context.spawn("inner-3", tellProbeWhenReady)
                return .receiveMessage { _ in .same }
            }
        )

        // once we get all ready messages here, we know the tree is "ready" and the tests which perform assertions on it can run
        _ = try! probe.expectMessages(count: 6)
        probe.stop() // stopping a probe however is still asynchronous...
        // thus we make use of the fact we know probe internals and that the expectNoMessage still will work in this situation
        try! probe.expectNoMessage(for: .milliseconds(300))
    }

    func test_printTree_shouldPrintActorTree() throws {
        self.system._printTree()
    }

    func test_traverse_shouldTraverseAllActors() throws {
        var seen: Set<String> = []

        self.system._traverseAllVoid { _, ref in
            if ref.address.name != "traversalProbe", !ref.address.name.starts(with: "$") { // skip subReceive, etc.
                seen.insert(ref.address.name)
            }
            return .continue
        }

        seen.shouldEqual(
            [
                "system",
                "receptionist",
                // "gossip", // TODO: should it also be here?
                "clusterEvents",
                "user",
                "other",
                "inner-1",
                "inner-2",
                "inner-3",
                "hello",
                "world",
            ]
        )
    }

    func test_traverse_shouldAllowImplementingCollect() {
        let found: _TraversalResult<String> = self.system._traverseAll { _, ref in
            if ref.address.name.contains("inner") {
                // collect it
                return .accumulateSingle(ref.address.name)
            } else {
                return .continue
            }
        }

        switch found {
        case .results(let inners):
            inners.shouldContain("inner-1")
            inners.shouldContain("inner-2")
            inners.shouldContain("inner-3")
            inners.count.shouldEqual(3)
        default:
            fatalError("Should never happen. Traversal should have returned only the inner ones. Was: \(found)")
        }
    }

    func test_traverse_shouldHaveRightDepthInContext() {
        let _: _TraversalResult<String> = self.system._traverseAll { context, ref in
            if ref.address.name == "hello" {
                context.depth.shouldEqual(1)
                return .continue
            } else if ref.address.name == "world" {
                context.depth.shouldEqual(2)
                return .continue
            } else {
                return .continue
            }
        }
    }
}
