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

class ActorDeferTests: XCTestCase {
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

    enum ReductionReaction {
        case staysSame
        case stops
        case failsByThrowing
    }

    func receiveDeferBehavior(_ probe: ActorRef<String>, deferUntil: DeferUntilWhen, whenActor reaction: ReductionReaction) -> Behavior<String> {
        return .receive { context, message in
            probe.tell("message:\(message)")
            context.defer(until: deferUntil) {
                probe.tell("defer:\(deferUntil)-1")
            }
            context.defer(until: deferUntil) {
                probe.tell("defer:\(deferUntil)-2")
            }

            switch reaction {
            case .staysSame: return .same
            case .stops: return .stop
            case .failsByThrowing: throw TestError("Failing on purpose")
            }
        }
    }

    func shared_defer_shouldExecute(deferUntil: DeferUntilWhen, whenActor reaction: ReductionReaction) throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = self.receiveDeferBehavior(p.ref, deferUntil: deferUntil, whenActor: reaction)

        let worker = try system.spawn(.anonymous, behavior)
        worker.tell("hello")

        try p.expectMessage("message:hello")
        try p.expectMessage("defer:\(deferUntil)-2")
        try p.expectMessage("defer:\(deferUntil)-1")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func shared_defer_shouldNotExecute(deferUntil: DeferUntilWhen, whenActor reaction: ReductionReaction) throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<String> = self.receiveDeferBehavior(p.ref, deferUntil: deferUntil, whenActor: reaction)

        let worker = try system.spawn(.anonymous, b)
        worker.tell("hello")

        try p.expectMessage("message:hello")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: .received) {}

    func test_defer_untilReceived_shouldExecute_whenStayingSame() throws {
        try self.shared_defer_shouldExecute(deferUntil: .received, whenActor: .staysSame)
    }

    func test_defer_untilReceived_shouldExecute_afterNoError_whenStopping() throws {
        try self.shared_defer_shouldExecute(deferUntil: .received, whenActor: .stops)
    }

    func test_defer_untilReceived_shouldExecute_afterError() throws {
        try self.shared_defer_shouldExecute(deferUntil: .received, whenActor: .failsByThrowing)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: .terminated) {}

    func test_defer_untilTerminated_shouldNotExecute_whenStayingSame() throws {
        try self.shared_defer_shouldNotExecute(deferUntil: .terminated, whenActor: .staysSame)
    }

    func test_defer_untilTerminated_shouldExecute_whenStopping() throws {
        try self.shared_defer_shouldExecute(deferUntil: .terminated, whenActor: .stops)
    }

    func test_defer_untilTerminated_shouldExecute_afterError() throws {
        try self.shared_defer_shouldExecute(deferUntil: .terminated, whenActor: .failsByThrowing)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: .failed) {}

    func test_defer_untilFailed_shouldNotExecute_whenStayingSame() throws {
        try self.shared_defer_shouldNotExecute(deferUntil: .failed, whenActor: .staysSame)
    }

    func test_defer_untilFailed_shouldNotExecute_whenStopping() throws {
        try self.shared_defer_shouldNotExecute(deferUntil: .failed, whenActor: .stops)
    }

    func test_defer_untilFailed_shouldExecute_afterError() throws {
        try self.shared_defer_shouldExecute(deferUntil: .failed, whenActor: .failsByThrowing)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: .receiveFailed) {}

    func test_defer_untilReceiveFailed_shouldNotExecute_whenStayingSame() throws {
        try self.shared_defer_shouldNotExecute(deferUntil: .receiveFailed, whenActor: .staysSame)
    }

    func test_defer_untilReceiveFailed_shouldNotExecute_whenStopping() throws {
        try self.shared_defer_shouldNotExecute(deferUntil: .receiveFailed, whenActor: .stops)
    }

    func test_defer_untilReceiveFailed_shouldExecute_afterError() throws {
        try self.shared_defer_shouldExecute(deferUntil: .receiveFailed, whenActor: .failsByThrowing)
    }

    func test_defer_untilReceiveFailed_shouldNotCarryOverToNextReceiveReduction() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<String> = .receive { context, message in
            p.tell("message:\(message)")

            if message == "first" {
                context.defer(until: .receiveFailed) {
                    p.tell("defer:receiveFailed-1")
                }
            }

            context.defer(until: .received) {
                p.tell("defer:\(message)-2")
            }

            if message == "second" {
                throw TestError("\(message)")
            }

            return .same
        }

        let worker = try system.spawn(.anonymous, b)
        worker.tell("first")
        worker.tell("second")

        try p.expectMessage("message:first")
        try p.expectMessage("defer:first-2")
        try p.expectMessage("message:second")
        try p.expectMessage("defer:second-2")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: mix) {}

    func test_mixedDefers_shouldExecuteAtRightPointsInTime_failed() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<String> = .receive { context, first in
            p.tell("first:\(first)")

            context.defer(until: .received) {
                p.tell("defer:first-received-1")
            }
            context.defer(until: .failed) {
                p.tell("defer:first-failed-2")
            }
            context.defer(until: .terminated) {
                p.tell("defer:first-terminated-3")
            }

            return .receiveMessage { second in
                p.tell("second:\(second)")

                context.defer(until: .received) {
                    p.tell("defer:second-received-4")
                }
                context.defer(until: .failed) {
                    p.tell("defer:second-failed-5")
                }
                context.defer(until: .terminated) {
                    p.tell("defer:second-terminated-6")
                }

                throw TestError("Boom")
            }
        }

        let worker = try system.spawn(.anonymous, b)
        worker.tell("hello")

        try p.expectMessage("first:hello")
        try p.expectMessage("defer:first-received-1")
        try p.expectNoMessage(for: .milliseconds(50))

        worker.tell("hi")
        try p.expectMessage("second:hi")
        // .received must trigger immediately, same as a Swift defer would
        try p.expectMessage("defer:second-received-4")

        // lifecycle bound ones trigger in reverse order thanks to .stop now
        try p.expectMessage("defer:second-terminated-6")
        try p.expectMessage("defer:second-failed-5")
        try p.expectMessage("defer:first-terminated-3")
        try p.expectMessage("defer:first-failed-2")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func test_mixedDefers_shouldExecuteAtRightPointsInTime_stopped() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<String> = .receive { context, first in
            p.tell("first:\(first)")

            context.defer(until: .received) {
                p.tell("defer:first-received-1")
            }
            context.defer(until: .failed) {
                p.tell("defer:first-failed-2")
            }
            context.defer(until: .terminated) {
                p.tell("defer:first-terminated-3")
            }

            return .receiveMessage { second in
                p.tell("second:\(second)")

                context.defer(until: .received) {
                    p.tell("defer:second-received-4")
                }
                context.defer(until: .failed) {
                    p.tell("defer:second-failed-5")
                }
                context.defer(until: .terminated) {
                    p.tell("defer:second-terminated-6")
                }

                return .stop
            }
        }

        let worker = try system.spawn(.anonymous, b)
        worker.tell("hello")

        try p.expectMessage("first:hello")
        try p.expectMessage("defer:first-received-1")
        try p.expectNoMessage(for: .milliseconds(50))

        worker.tell("hi")
        try p.expectMessage("second:hi")
        // .received must trigger immediately, same as a Swift defer would
        try p.expectMessage("defer:second-received-4")

        // lifecycle bound ones trigger in reverse order thanks to .stop now
        try p.expectMessage("defer:second-terminated-6")
        // should not trigger, was not a failure: defer:second-failed-5
        try p.expectMessage("defer:first-terminated-3")
        // should not trigger, was not a failure: defer:first-failed-2
        try p.expectNoMessage(for: .milliseconds(50))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: context.defer(until: .received) { context.defer(until: .received) }

    // TODO: could be implemented if we really want to keep context.defer and keep semantics as close to Swift as possible
    func skip_nestedDefer_shouldMatchSwiftSemantics() throws {
        // sanity check
        let s = self.testKit.spawnTestProbe(expecting: String.self)
        func deferSemanticsSanityCheck() {
            defer { s.tell("A") }
            defer { s.tell("B") }
            defer {
                defer {
                    s.tell("NEST")
                }
                s.tell("C")
            }
            s.tell("message")
        }
        deferSemanticsSanityCheck()
        try s.expectMessages(count: 5).shouldEqual(["message", "C", "NEST", "B", "A"])

        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<String> = .receive { context, string in
            context.defer(until: .received) { p.tell("A") }
            context.defer(until: .received) { p.tell("B") }
            context.defer(until: .received) {
                context.defer(until: .received) {
                    p.tell("NEST")
                }
                p.tell("C")
            }
            p.tell("message:\(string)")
            return .stop
        }

        let worker = try system.spawn(.anonymous, b)
        worker.tell("hello")

        try p.expectMessages(count: 5).shouldEqual(["message:hello", "C", "NEST", "B", "A"])
    }

    // regression test for a bug caused by not setting the actor behavior to failed
    // in case canonicalization after setup fails
    func test_executeDefer_whenSetupReturnsSame() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let b: Behavior<Never> = .setup { context in
            context.defer(until: .terminated) {
                p.tell("A")
            }
            return .same
        }

        _ = try self.system.spawn(.anonymous, b)

        try p.expectMessage("A")
    }
}
