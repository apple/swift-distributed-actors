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

    override func setUp() {
        self.system = ActorSystem("TraversalTests")
        let _: ActorRef<String> = try! self.system.spawn(.setup { context in
            let _: ActorRef<String> = try context.spawn(.ignore, name: "world")
            return .same
        }, name: "hello")

        let _: ActorRef<String> = try! self.system.spawn(.setup { context in
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-1")
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-2")
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-3")
            return .same
        }, name: "other")

        sleep(1)
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
                pinfo("Visit: \(ref)")
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
    }

}
