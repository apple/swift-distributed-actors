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
import NIO

class ActorAskTests: XCTestCase {
    let system = ActorSystem("AskSupportTestsSystem")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
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

        let response = ref.ask(for: String.self, timeout: .milliseconds(1)) { TestMessage(replyTo: $0) }

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
}
