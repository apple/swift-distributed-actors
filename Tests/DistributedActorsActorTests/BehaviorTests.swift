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

class BehaviorTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }

    public struct TestMessage {
        let message: String
        let replyTo: ActorRef<String>
    }

    func test_setup_executesImmediatelyOnStartOfActor() throws {
        let p: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

        let message = "EHLO"
        let _: ActorRef<String> = try! system.spawnAnonymous(.setup { context in
            p ! message
            return .stopped
        })

        try p.expectMessage(message)
    }

    func test_single_actor_should_wakeUp_on_new_message_lockstep() throws {
        let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-2", on: system)

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        for _ in 0...10 {
            let payload: String = messages.nextName()
            p ! payload
            try p.expectMessage(payload)
        }
    }

    func test_two_actors_should_wakeUp_on_new_message_lockstep() throws {
        let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-3", on: system)

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        let echoPayload: ActorRef<TestMessage> =
            try system.spawnAnonymous(.receiveMessage { message in
                p ! message.message
                return .same
            })

        for _ in 0...10 {
            let payload: String = messages.nextName()
            echoPayload ! TestMessage(message: payload, replyTo: p.ref)
            try p.expectMessage(payload)
        }
    }

    func test_receive_shouldReceiveManyMessagesInExpectedOrder() throws {
//    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-4", on: system)

        func countTillNThenDieBehavior(n: Int, currentlyAt at: Int = -1) -> Behavior<Int> {
            if at == n {
                return .setup { context in
                    return .stopped
                }
            } else {
                return .receive { context, message in
                    if (message == at + 1) {
                        return countTillNThenDieBehavior(n: n, currentlyAt: message)
                    } else {
                        fatalError("Received \(message) when was expecting \(at + 1)! Ordering rule violated.")
                    }
                }
            }
        }

        let n = 10
        let ref = try system.spawn(countTillNThenDieBehavior(n: n), named: "countTill\(n)")

        // first we send many messages
        for i in 0...n {
            ref ! i
        }

        Thread.sleep(.milliseconds(600))
    }

    class MyActor: ActorBehavior<TestMessage> {
        override public func receive(context: ActorContext<TestMessage>, message: TestMessage) -> Behavior<TestMessage> {
            message.replyTo ! thxFor(message.message)
            return .same
        }

        override func receiveSignal(context: ActorContext<BehaviorTests.TestMessage>, signal: Signal) -> Behavior<BehaviorTests.TestMessage> {
            return .ignore
        }

        func thxFor(_ m: String) -> String {
            return "Thanks for: <\(m)>"
        }
    }

    func test_ActorBehavior_receivesMessages() throws {
        let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-5", on: system)

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        let ref: ActorRef<TestMessage> = try system.spawnAnonymous(MyActor())

        // first we send many messages
        for i in 0...10 {
            ref ! TestMessage(message: "message-\(i)", replyTo: p.ref)
        }

        func thxFor(_ m: String) -> String {
            return "Thanks for: <\(m)>"
        }

        // separately see if we got the expected replies in the right order.
        // we do so separately to avoid sending in "lock-step" in the first loop above here
        for i in 0...10 {
            // TODO: make expectMessage()! that can terminate execution
            try p.expectMessage(thxFor("message-\(i)"))
        }
    }

    func test_expectNoMessage() throws {
        let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-6", on: system)

        try p.expectNoMessage(for: .milliseconds(100))
    }
}
