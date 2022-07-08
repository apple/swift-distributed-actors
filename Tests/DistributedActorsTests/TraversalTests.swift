//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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

final class TraversalTests: ClusterSystemXCTestCase {
    struct ActorReady: Codable {
        let name: String
    }

    override func setUp() {
        super.setUp()

        // we use the probe to make sure all actors are started before we start asserting on the tree
        let probe = self.testKit.makeTestProbe(expecting: ActorReady.self)

        let tellProbeWhenReady: _Behavior<Int> = .setup { context in
            probe.tell(ActorReady(name: context.name))
            return .receiveMessage { _ in .same }
        }

        let _: _ActorRef<String> = try! self.system._spawn(
            "hello",
            .setup { context in
                probe.tell(ActorReady(name: context.name))
                let _: _ActorRef<Int> = try context._spawn("world", tellProbeWhenReady)
                return .receiveMessage { _ in .same }
            }
        )

        let _: _ActorRef<String> = try! self.system._spawn(
            "other",
            .setup { context in
                probe.tell(ActorReady(name: context.name))
                let _: _ActorRef<Int> = try context._spawn("inner-1", tellProbeWhenReady)
                let _: _ActorRef<Int> = try context._spawn("inner-2", tellProbeWhenReady)
                let _: _ActorRef<Int> = try context._spawn("inner-3", tellProbeWhenReady)
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

    func test_traverse_shouldAllowImplementingCollect() {
        let found: _TraversalResult<String> = self.system._traverseAll { _, ref in
            if ref.id.name.contains("inner") {
                // collect it
                return .accumulateSingle(ref.id.name)
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
            if ref.id.name == "hello" {
                context.depth.shouldEqual(1)
                return .continue
            } else if ref.id.name == "world" {
                context.depth.shouldEqual(2)
                return .continue
            } else {
                return .continue
            }
        }
    }
}
