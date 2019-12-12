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

import DistributedActors
import struct DistributedActors.TimeAmount
import DistributedActorsTestKit
import Foundation
import XCTest

final class ActorAskTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.system = nil
        self.testKit = nil
    }

    struct TestMessage {
        let replyTo: ActorRef<String>
    }

    func test_ask_shouldSucceedIfResponseIsReceivedBeforeTimeout() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received")
            return .stop
        }

        let ref = try system.spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        let result = try response.nioFuture.wait()

        result.shouldEqual("received")
    }

    func test_ask_shouldFailIfResponseIsNotReceivedBeforeTimeout() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage { _ in
            .stop
        }

        let ref = try system.spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        shouldThrow(expected: TimeoutError.self) {
            _ = try response.nioFuture.wait()
        }
    }

    func test_ask_shouldCompleteWithFirstResponse() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received:1")
            $0.replyTo.tell("received:2")
            return .stop
        }

        let ref = try system.spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .milliseconds(1)) { TestMessage(replyTo: $0) }

        let result = try response.nioFuture.wait()

        result.shouldEqual("received:1")
    }

    struct AnswerMePlease {
        let replyTo: ActorRef<String>
    }

    func test_askResult_shouldBePossibleTo_contextAwaitOn() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let greeter: ActorRef<AnswerMePlease> = try system.spawn("greeterAskReply", .receiveMessage { message in
            message.replyTo.tell("Hello there")
            return .stop
        })

        let _: ActorRef<Never> = try system.spawn("awaitOnAskResult", .setup { context in
            let askResult = greeter.ask(for: String.self, timeout: .seconds(1)) { AnswerMePlease(replyTo: $0) }

            return context.awaitResultThrowing(of: askResult, timeout: .seconds(1)) { greeting in
                p.tell(greeting)
                return .stop
            }
        })

        try p.expectMessage("Hello there")
    }

    func shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout timeout: TimeAmount) throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let greeter: ActorRef<AnswerMePlease> = try system.spawn(
            "greeterAskReply",
            .receiveMessage { message in
                message.replyTo.tell("Hello there")
                return .stop
            }
        )

        let _: ActorRef<Never> = try system.spawn("askingAndOnResultAsyncThrowing", .setup { context in
            let askResult = greeter.ask(for: String.self, timeout: timeout) { replyTo in
                AnswerMePlease(replyTo: replyTo)
            }

            context.onResultAsyncThrowing(of: askResult, timeout: timeout) { greeting in
                p.tell(greeting)
                return .same
            }

            // TODO: cannot become .ignore since that results in "become .same in .setup"
            // See also issue #746
            return .receiveMessage { _ in .same }
        })

        try p.expectMessage("Hello there", within: .seconds(3))
    }

    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withNormalTimeout() throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .seconds(1))
    }

    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withInfiniteTimeout() throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .effectivelyInfinite)
    }

    func test_askResult_whenContextAwaitedOn_shouldRespectTimeout() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let void: ActorRef<AnswerMePlease> = try system.spawn("theVoid", (.receiveMessage { _ in .same }))

        let _: ActorRef<Never> = try system.spawn("onResultAsync", .setup { context in
            let askResult = void
                .ask(for: String.self, timeout: .seconds(1)) { AnswerMePlease(replyTo: $0) }

            return context.awaitResult(of: askResult, timeout: .milliseconds(100)) { greeting in
                switch greeting {
                case .failure(let err):
                    p.tell("\(err)")
                case .success:
                    p.tell("no timeout...")
                }
                return .stop
            }
        })

        var msg = "TimeoutError("
        msg += "message: \"AskResponse<String> timed out after 100ms\", "
        msg += "timeout: TimeAmount(100ms, nanoseconds: 100000000))"
        try p.expectMessage(msg)
    }

    func test_ask_onDeadLetters_shouldPutMessageIntoDeadLetters() throws {
        let ref = system.deadLetters.adapt(from: AnswerMePlease.self)

        let result = ref.ask(for: String.self, timeout: .milliseconds(300)) {
            AnswerMePlease(replyTo: $0)
        }

        shouldThrow(expected: TimeoutError.self) {
            try result.nioFuture.wait()
        }
    }

    func test_ask_withTerminatedSystem_shouldNotCauseCrash() throws {
        let system = ActorSystem("AskCrashSystem")

        let ref = try system.spawn(.unique("responder"), of: TestMessage.self, .receiveMessage { message in
            message.replyTo.tell("test")
            return .same
        })

        system.shutdown().wait()

        _ = ref.ask(for: String.self, timeout: .milliseconds(300)) { replyTo in
            TestMessage(replyTo: replyTo)
        }
    }
}
