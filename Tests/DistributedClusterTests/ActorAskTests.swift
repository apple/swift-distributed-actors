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

@testable import DistributedCluster
import DistributedActorsTestKit
import Foundation
import XCTest

final class ActorAskTests: SingleClusterSystemXCTestCase {
    struct TestMessage: Codable {
        let replyTo: _ActorRef<String>
    }

    func test_ask_forSimpleType() async throws {
        let behavior: _Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received")
            return .stop
        }

        let ref = try system._spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        let result = try await response.value

        result.shouldEqual("received")
    }

    func test_ask_shouldSucceedIfResponseIsReceivedBeforeTimeout() async throws {
        let behavior: _Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received")
            return .stop
        }

        let ref = try system._spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        let result = try await response.value

        result.shouldEqual("received")
    }

    func test_ask_shouldFailIfResponseIsNotReceivedBeforeTimeout() async throws {
        let behavior: _Behavior<TestMessage> = .receiveMessage { _ in
            .stop
        }

        let ref = try system._spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .seconds(1)) { TestMessage(replyTo: $0) }

        let error = try await shouldThrow {
            _ = try await response.value
        }

        guard let remoteCallError = error as? RemoteCallError, case .timedOut = remoteCallError.underlying.error else {
            throw testKit.fail("Expected RemoteCallError.timedOut, got \(error)")
        }
    }

    func test_ask_shouldCompleteWithFirstResponse() async throws {
        let behavior: _Behavior<TestMessage> = .receiveMessage {
            $0.replyTo.tell("received:1")
            $0.replyTo.tell("received:2")
            return .stop
        }

        let ref = try system._spawn(.anonymous, behavior)

        let response = ref.ask(for: String.self, timeout: .milliseconds(1)) { TestMessage(replyTo: $0) }

        let result = try await response.value

        result.shouldEqual("received:1")
    }

    struct AnswerMePlease: Codable {
        let replyTo: _ActorRef<String>
    }

    func test_askResult_shouldBePossibleTo_contextAwaitOn() throws {
        let p = testKit.makeTestProbe(expecting: String.self)

        let greeter: _ActorRef<AnswerMePlease> = try system._spawn(
            "greeterAskReply",
            .receiveMessage { message in
                message.replyTo.tell("Hello there")
                return .stop
            }
        )

        let _: _ActorRef<Never> = try system._spawn(
            "awaitOnAskResult",
            .setup { context in
                let askResult = greeter.ask(for: String.self, timeout: .seconds(1)) { AnswerMePlease(replyTo: $0) }

                return context.awaitResultThrowing(of: askResult, timeout: .seconds(1)) { greeting in
                    p.tell(greeting)
                    return .stop
                }
            }
        )

        try p.expectMessage("Hello there")
    }

    func shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout timeout: Duration) throws {
        let p = testKit.makeTestProbe(expecting: String.self)

        let greeter: _ActorRef<AnswerMePlease> = try system._spawn(
            "greeterAskReply",
            .receiveMessage { message in
                message.replyTo.tell("Hello there")
                return .stop
            }
        )

        let _: _ActorRef<Int> = try system._spawn(
            "askingAndOnResultAsyncThrowing",
            .setup { context in
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
            }
        )

        try p.expectMessage("Hello there", within: .seconds(3))
    }

    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withNormalTimeout() throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .seconds(1))
    }

    func test_askResult_shouldBePossibleTo_contextOnResultAsyncOn_withInfiniteTimeout() throws {
        try self.shared_askResult_shouldBePossibleTo_contextOnResultAsyncOn(withTimeout: .effectivelyInfinite)
    }

    func test_askResult_whenContextAwaitedOn_shouldRespectTimeout() throws {
        let p = testKit.makeTestProbe(expecting: String.self)

        let void: _ActorRef<AnswerMePlease> = try system._spawn("theVoid", (.receiveMessage { _ in .same }))

        let _: _ActorRef<Never> = try system._spawn(
            "onResultAsync",
            .setup { context in
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
            }
        )

        let message = try p.expectMessage()
        message.shouldStartWith(prefix: "RemoteCallError(timedOut(")
        message.shouldContain("DistributedCluster.TimeoutError(message: \"AskResponse<String> timed out after 100ms\", timeout: 0.1 seconds))")
    }

    func test_ask_onDeadLetters_shouldPutMessageIntoDeadLetters() async throws {
        let ref = system.deadLetters.adapt(from: AnswerMePlease.self)

        let result = ref.ask(for: String.self, timeout: .milliseconds(300)) {
            AnswerMePlease(replyTo: $0)
        }

        let error = try await shouldThrow {
            try await result.value
        }

        guard let remoteCallError = error as? RemoteCallError, case .timedOut = remoteCallError.underlying.error else {
            throw testKit.fail("Expected RemoteCallError.timedOut, got \(error)")
        }
    }

    func test_ask_withTerminatedSystem_shouldNotCauseCrash() async throws {
        let system = await self.setUpNode("AskCrashSystem")

        let ref = try system._spawn(
            .unique("responder"),
            of: TestMessage.self,
            .receiveMessage { message in
                message.replyTo.tell("test")
                return .same
            }
        )

        try! await system.shutdown().wait()

        _ = ref.ask(for: String.self, timeout: .milliseconds(300)) { replyTo in
            TestMessage(replyTo: replyTo)
        }
    }
}
