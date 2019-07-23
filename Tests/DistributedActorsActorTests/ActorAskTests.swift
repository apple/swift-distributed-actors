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
import Swift Distributed ActorsActor
import struct Swift Distributed ActorsActor.TimeAmount
import SwiftDistributedActorsActorTestKit

final class ActorAskTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    struct TestMessage {
        let replyTo: ActorRef<String>
    }

    func test_ask_shouldSucceedIfResponseIsReceivedBeforeTimeout() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received")
            return .stopped
        }

        let ref = try system.spawnAnonymous(behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        let result = try response.nioFuture.wait()

        result.shouldEqual("received")
    }

    func test_ask_shouldFailIfResponseIsNotReceivedBeforeTimeout() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage { _ in
            return .stopped
        }

        let ref = try system.spawnAnonymous(behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        shouldThrow(expected: TimeoutError.self) {
            _ = try response.nioFuture.wait()
        }
    }

    func test_ask_shouldCompleteWithFirstResponse() throws {
        let behavior: Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received:1")
            $0.replyTo.tell("received:2")
            return .stopped
        }

        let ref = try system.spawnAnonymous(behavior)

        let response = ref.ask(for: String.self, timeout: .milliseconds(1)) { TestMessage(replyTo: $0) }

        let result = try response.nioFuture.wait()

        result.shouldEqual("received:1")
    }

    struct AnswerMePlease {
        let replyTo: ActorRef<String>
    }

    func test_askResult_shouldBePossibleTo_contextAwaitOn() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let greeter: ActorRef<AnswerMePlease> = try system.spawn(.receiveMessage { message in
            message.replyTo.tell("Hello there")
            return .stopped
        }, name: "greeterAskReply")

        let _: ActorRef<Never> = try system.spawn(.setup { context in
            let askResult = greeter.ask(for: String.self, timeout: .seconds(1)) { AnswerMePlease(replyTo: $0) }

            return context.awaitResultThrowing(of: askResult, timeout: .seconds(1)) { greeting in
                p.tell(greeting)
                return .stopped
            }
        }, name: "awaitOnAskResult")

        try p.expectMessage("Hello there")
    }

    func shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout timeout: TimeAmount) throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let greeter: ActorRef<AnswerMePlease> = try system.spawn(.receiveMessage { message in
            message.replyTo.tell("Hello there")
            return .stopped
        }, name: "greeterAskReply")

        let _: ActorRef<Never> = try system.spawn(.setup { context in
            let askResult = greeter.ask(for: String.self, timeout: timeout) { replyTo in
                AnswerMePlease(replyTo: replyTo)
            }

            context.onResultAsyncThrowing(of: askResult, timeout: timeout) { greeting in
                p.tell(greeting)
                return .same
            }

            // TODO: cannot become .ignore since that results in "become .same in .setup"
            // See also https://github.com/apple/swift-distributed-actors/issues/746
            return .receiveMessage { _ in .same }
        }, name: "askingAndOnResultAsyncThrowing")

        try p.expectMessage("Hello there", within: .seconds(3))
    }
    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withNormalTimeout()  throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .seconds(1))
    }
    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withInfiniteTimeout() throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .effectivelyInfinite)
    }

    func test_askResult_whenContextAwaitedOn_shouldRespectTimeout() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let void: ActorRef<AnswerMePlease> = try system.spawn(.receiveMessage { message in .same }, name: "theVoid")

        let _: ActorRef<Never> = try system.spawn(.setup { context in
            let askResult = void
                .ask(for: String.self, timeout: .seconds(1)) { AnswerMePlease(replyTo: $0) }

            return context.awaitResult(of: askResult, timeout: .milliseconds(100)) { greeting in
                switch greeting {
                case .failure(let err):
                    p.tell("\(err)")
                case .success:
                    p.tell("no timeout...")
                }
                return .stopped
            }
        }, name: "onResultAsync")

        var msg = "ExecutionError(underlying: "
        msg += "Swift Distributed ActorsActor.TimeoutError("
        msg += "message: \"AskResponse<String> timed out after 100ms\", "
        msg += "timeout: TimeAmount(100ms, nanoseconds: 100000000))"
        msg += ")"
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
}
