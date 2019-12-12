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
import Foundation
import XCTest

class BehaviorCanonicalizeTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.system = nil
        self.testKit = nil
    }

    func test_canonicalize_nestedSetupBehaviors() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("canonicalizeProbe1")

        let b: Behavior<String> = .setup { _ in
            p.tell("outer-1")
            return .setup { _ in
                p.tell("inner-2")
                return .setup { _ in
                    p.tell("inner-3")
                    return .receiveMessage { m in
                        p.tell("received:\(m)")
                        return .same
                    }
                }
            }
        }

        let ref = try system.spawn("nestedSetups", b)

        try p.expectMessage("outer-1")
        try p.expectMessage("inner-2")
        try p.expectMessage("inner-3")
        try p.expectNoMessage(for: .milliseconds(100))
        ref.tell("ping")
        try p.expectMessage("received:ping")
    }

    func test_canonicalize_doesSurviveDeeplyNestedSetups() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("canonicalizeProbe2")

        func deepSetupRabbitHole(currentDepth depth: Int, stopAt limit: Int) -> Behavior<String> {
            return .setup { _ in
                if depth < limit {
                    // add another "setup layer"
                    return deepSetupRabbitHole(currentDepth: depth + 1, stopAt: limit)
                } else {
                    return .receiveMessage { msg in
                        p.tell("received:\(msg)")
                        return .stop
                    }
                }
            }
        }

        // we attempt to cause a stack overflow by nesting tons of setups inside each other.
        // this could fail if canonicalization were implemented in some naive way.
        let depthLimit = self.system.settings.actor.maxBehaviorNestingDepth - 2 // not a good idea, but we should not crash
        let ref = try system.spawn("deepSetupNestedRabbitHole", deepSetupRabbitHole(currentDepth: 0, stopAt: depthLimit))

        ref.tell("ping")
        try p.expectMessage("received:ping")
    }

    func test_canonicalize_unwrapInterceptBehaviors() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("canonicalizeProbe3")

        let b: Behavior<String> = .intercept(behavior: .setup { _ in
            p.tell("outer-1")
            return .setup { _ in
                p.tell("inner-2")
                return .receiveMessage { m in
                    p.tell("received:\(m)")
                    return .same
                }
            }
        }, with: ProbeInterceptor(probe: p))

        let ref = try system.spawn("nestedSetups", b)

        try p.expectMessage("outer-1")
        try p.expectMessage("inner-2")
        try p.expectNoMessage(for: .milliseconds(100))
        ref.tell("ping")
        try p.expectMessage("ping")
        try p.expectMessage("received:ping")
    }

    func test_canonicalize_orElse_shouldThrowOnTooDeeplyNestedBehaviors() throws {
        let p: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        var behavior: Behavior<Int> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        for i in (0 ... self.system.settings.actor.maxBehaviorNestingDepth).reversed() {
            behavior = Behavior<Int>.receiveMessage { message in
                if message == i {
                    p.tell(-i)
                    return .same
                } else {
                    return .unhandled
                }
            }.orElse(behavior)
        }

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)
        try p.expectTerminated(ref)
    }

    func test_canonicalize_orElse_executeNestedSetupOnBecome() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawn("orElseCanonicalizeNestedSetups", .receiveMessage { msg in
            let onlyA = Behavior<String>.setup { _ in
                p.ref.tell("setup:onlyA")
                return .receiveMessage { msg in
                    switch msg {
                    case "A":
                        p.ref.tell("got:A")
                        return .same
                    default: return .unhandled
                    }
                }
            }
            let onlyB = Behavior<String>.setup { _ in
                p.ref.tell("setup:onlyB")
                return .receiveMessage { msg in
                    switch msg {
                    case "B":
                        p.ref.tell("got:B")
                        return .same
                    default: return .unhandled
                    }
                }
            }
            return onlyA.orElse(onlyB)
        })

        ref.tell("run the setups")

        try p.expectMessage("setup:onlyA")
        try p.expectMessage("setup:onlyB")
        ref.tell("A")
        try p.expectMessage("got:A")
        ref.tell("B")
        try p.expectMessage("got:B")
    }

    func test_startBehavior_shouldThrowOnTooDeeplyNestedBehaviorSetups() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("startBehaviorProbe")

        /// Creates an infinitely nested setup behavior -- it is used to see that we detect this and abort executing eagerly
        func setupDaDoRunRunRunDaDoRunRun(depth: Int = 0) -> Behavior<String> {
            return .setup { _ in
                p.tell("at:\(depth)")
                return setupDaDoRunRunRunDaDoRunRun(depth: depth + 1)
            }
        }

        // TODO: if issue #244 is implemented, we cna supervise and "spy on" start() failures making this test much more specific

        let behavior = setupDaDoRunRunRunDaDoRunRun()
        _ = try system.spawn("nestedSetups", behavior)

        for depth in 0 ..< self.system.settings.actor.maxBehaviorNestingDepth {
            try p.expectMessage("at:\(depth)")
        }
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func test_stopWithoutPostStop_shouldUsePreviousBehavior() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = Behavior.receiveMessage { _ in
            .stop
        }.receiveSignal { _, signal in
            if signal is Signals.PostStop {
                p.tell("postStop")
            }
            return .same
        }

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")

        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }

    func test_stopWithPostStop_shouldUseItForPostStopSignalHandling() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = Behavior.receiveMessage { _ in
            .stop { _ in
                p.tell("postStop")
            }
        }

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")

        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }

    func test_setup_returningSameShouldThrow() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { _ in
            .same
        }

        let ref = try system.spawn(.anonymous, behavior)

        p.watch(ref)

        try p.expectTerminated(ref)
    }
}
