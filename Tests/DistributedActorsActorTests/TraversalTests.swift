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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import NIO
import NIOFoundationCompat
import SwiftDistributedActorsActorTestKit

class TraversalTests: XCTestCase {

    var system: ActorSystem! = nil
    lazy var testKit = ActorTestKit(system)

    struct ActorReady {
        let name: String
        init(_ name: String) {
            self.name = name
        }
    }

    override func setUp() {
        self.system = ActorSystem("TraversalTests")

        // we use the probe to make sure all actors are started before we start asserting on the tree
        let probe = testKit.spawnTestProbe(expecting: ActorReady.self)

        let tellProbeWhenReady: Behavior<Void> = .setup { context in
            probe.tell(ActorReady(context.name))
            return .same
        }

        let _: ActorRef<String> = try! self.system.spawn(.setup { context in
            probe.tell(ActorReady(context.name))
            let _: ActorRef<Void> = try context.spawn(tellProbeWhenReady, name: "world")
            return .same
        }, name: "hello")

        let _: ActorRef<String> = try! self.system.spawn(.setup { context in
            probe.tell(ActorReady(context.name))
            let _: ActorRef<Void> = try context.spawn(tellProbeWhenReady, name: "inner-1")
            let _: ActorRef<Void> = try context.spawn(tellProbeWhenReady, name: "inner-2")
            let _: ActorRef<Void> = try context.spawn(tellProbeWhenReady, name: "inner-3")
            return .same
        }, name: "other")

        // once we get all ready messages here, we know the tree is "ready" and the tests which perform assertions on it can run
        _ = try! probe.expectMessages(count: 6)
        probe.stop() // stopping a probe however is still asynchronous...
        // thus we make use of the fact we know probe internals and that the expectNoMessage still will work in this situation
        try! probe.expectNoMessage(for: .milliseconds(300))
    }

    override func tearDown() {
        system.terminate()
    }

    func test_printTree_shouldPrintActorTree() throws {
        self.system._printTree()
    }

    func test_traverse_shouldTraverseAllActors() throws {
        var seen: [String] = []

        self.system._traverseAllVoid { context, ref in
            if ref.path.name != "traversalProbe" {
                seen.append(ref.path.name)
            }
            return .continue
        }

        seen.shouldContain("user")
        seen.shouldContain("system")
        seen.shouldContain("hello")
        seen.shouldContain("world")
        seen.shouldContain("other")
        seen.shouldContain("inner-1")
        seen.shouldContain("inner-2")
        seen.shouldContain("inner-3")
        seen.count.shouldEqual(8)
    }

    func test_traverse_shouldAllowImplementingCollect() {
        let found: TraversalResult<String> = self.system._traverseAll { context, ref in
            if ref.path.name.contains("inner") {
                // collect it
                return .accumulateSingle(ref.path.name)
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
        let _: TraversalResult<String> = self.system._traverseAll { context, ref in
            if ref.path.name == "hello" {
                context.depth.shouldEqual(1)
                return .continue
            } else if ref.path.name == "world" {
                context.depth.shouldEqual(2)
                return .continue
            } else {
                return .continue
            }
        }
    }

}
