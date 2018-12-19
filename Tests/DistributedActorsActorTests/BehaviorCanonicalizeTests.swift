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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class BehaviorCanonicalizeTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        try! system.terminate()
    }

    func test_canonicalize_nestedSetupBehaviors() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe(name: "canonicalizeProbe1")

        let b: Behavior<String> = .setup { c1 in
            p.tell("outer-1")
            return .setup { c2 in
                p.tell("inner-2")
                return .setup { c2 in
                    p.tell("inner-3")
                    return .receiveMessage { m in
                        p.tell("received:\(m)")
                        return .same
                    }
                }
            }
        }

        let ref = try! system.spawn(b, name: "nestedSetups")

        try p.expectMessage("outer-1")
        try p.expectMessage("inner-2")
        try p.expectMessage("inner-3")
        try p.expectNoMessage(for: .milliseconds(100))
        ref.tell("ping")
        try p.expectMessage("received:ping")
    }

    func test_canonicalize_doesSurviveDeeplyNestedSetups() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe(name: "canonicalize-probe-2")

        func deepSetupRabbitHole(currentDepth depth: Int, stopAt limit: Int) -> Behavior<String> {
            return .setup { context in
                if depth < limit {
                    // add another "setup layer"
                    return deepSetupRabbitHole(currentDepth: depth + 1, stopAt: limit)
                } else {
                    return .receiveMessage { msg in
                        p.tell("received:\(msg)")
                        return .stopped
                    }
                }
            }
        }

        // we attempt to cause a stack overflow by nesting tons of setups inside each other.
        // this could fail if canonicalization were implemented in some naive way.
        let depthLimit = 1024 * 8 // not a good idea, but we should not crash
        let ref = try! system.spawn(deepSetupRabbitHole(currentDepth: 0, stopAt: depthLimit), name: "deepSetupNestedRabbitHole")

        ref.tell("ping")
        try p.expectMessage("received:ping")
    }

}
