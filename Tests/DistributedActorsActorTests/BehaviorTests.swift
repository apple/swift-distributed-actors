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
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }

    public struct TestMessage {
        let message: String
        let replyTo: ActorRef<String>
    }

    func test_setup_executesImmediatelyOnStartOfActor() throws {
        let p = testKit.spawnTestProbe(name: "testActor-1", expecting: String.self)

        let message = "EHLO"
        let _: ActorRef<String> = try system.spawnAnonymous(.setup { context in
            p.tell(message)
            return .stopped
        })

        try p.expectMessage(message)
    }

    func test_single_actor_should_wakeUp_on_new_message_lockstep() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe(name: "testActor-2")

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        for _ in 0...10 {
            let payload: String = messages.nextName()
            p.tell(payload)
            try p.expectMessage(payload)
        }
    }

    func test_two_actors_should_wakeUp_on_new_message_lockstep() throws {
        let p = testKit.spawnTestProbe(name: "testActor-2", expecting: String.self)

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        let echoPayload: ActorRef<TestMessage> =
            try system.spawnAnonymous(.receiveMessage { message in
                p.tell(message.message)
                return .same
            })

        for _ in 0...10 {
            let payload: String = messages.nextName()
            echoPayload.tell(TestMessage(message: payload, replyTo: p.ref))
            try p.expectMessage(payload)
        }
    }

    func test_receive_shouldReceiveManyMessagesInExpectedOrder() throws {
        let p = testKit.spawnTestProbe(name: "testActor-3", expecting: Int.self)

        func countTillNThenDieBehavior(n: Int, currentlyAt at: Int = -1) -> Behavior<Int> {
            if at == n {
                return .setup { context in
                    return .stopped
                }
            } else {
                return .receive { context, message in
                    if (message == at + 1) {
                        p.tell(message)
                        return countTillNThenDieBehavior(n: n, currentlyAt: message)
                    } else {
                        fatalError("Received \(message) when was expecting \(at + 1)! Ordering rule violated.")
                    }
                }
            }
        }

        let n = 10
        let ref = try system.spawn(countTillNThenDieBehavior(n: n), name: "countTill\(n)")

        // first we send many messages
        for i in 0...n {
            ref.tell(i)
        }

        // then we expect they arrive in the expected order
        for i in 0...n {
            try p.expectMessage(i)
        }
    }

    // TODO: another test with 2 senders, that either of their ordering is valid at recipient

    class MyActor: ActorBehavior<TestMessage> {
        override public func receive(context: ActorContext<TestMessage>, message: TestMessage) -> Behavior<TestMessage> {
            message.replyTo.tell(thxFor(message.message))
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
        let p: ActorTestProbe<String> = testKit.spawnTestProbe(name: "testActor-5")

        let messages = NotSynchronizedAnonymousNamesGenerator(prefix: "message-")

        let ref: ActorRef<TestMessage> = try system.spawnAnonymous(MyActor())

        // first we send many messages
        for i in 0...10 {
            ref.tell(TestMessage(message: "message-\(i)", replyTo: p.ref))
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

    enum OrElseProtocol {
        case first
        case second
        case other
    }

    func firstBehavior(_ probe: ActorRef<OrElseProtocol>) -> Behavior<OrElseProtocol> {
        return .receiveMessage { message in
            switch message {
            case .first:
                probe.tell(.first)
                return .same
            case .second:
                return .unhandled
            default:
                return .ignore
            }
        }
    }

    func secondBehavior(_ probe: ActorRef<OrElseProtocol>) -> Behavior<OrElseProtocol> {
        return .receiveMessage { message in
            probe.tell(message)
            return .same
        }
    }

    func combinedBehavior(_ probe: ActorRef<OrElseProtocol>) -> Behavior<OrElseProtocol> {
        return firstBehavior(probe).orElse(secondBehavior(probe))
    }

    func test_orElse_shouldExecuteFirstBehavior() throws {
        let p: ActorTestProbe<OrElseProtocol> = testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawnAnonymous(combinedBehavior(p.ref))

        ref.tell(.first)
        try p.expectMessage(.first)
    }

    func test_orElse_shouldExecuteSecondBehavior() throws {
        let p: ActorTestProbe<OrElseProtocol> = testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawnAnonymous(combinedBehavior(p.ref))

        ref.tell(.second)
        try p.expectMessage(.second)
    }

    func test_orElse_shouldNotExecuteSecondBehaviorOnIgnore() throws {
        let p: ActorTestProbe<OrElseProtocol> = testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawnAnonymous(combinedBehavior(p.ref))

        ref.tell(.other)
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_orElse_shouldProperlyHandleDeeplyNestedBehaviors() throws {
        let p: ActorTestProbe<Int> = testKit.spawnTestProbe()
        var behavior: Behavior<Int> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        for i in (0...100).reversed() {
            behavior = Behavior<Int>.receiveMessage { message in
                if message == i {
                    p.tell(-i)
                    return .same
                } else {
                    return .unhandled
                }
            }.orElse(behavior)
        }

        let ref = try system.spawnAnonymous(behavior)

        ref.tell(50)
        try p.expectMessage(-50)

        p.tell(255)
        try p.expectMessage(255)
    }

    func test_stoppedWithPostStop_shouldTriggerPostStopCallback() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<Never> = .stopped { _ in
            p.tell("postStop")
        }

        _ = try system.spawnAnonymous(behavior)

        try p.expectMessage("postStop")
    }

    enum TestError: Error {
        case error
    }

    func test_stoppedWithPostStopThrows_shouldTerminate() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<Never> = .stopped(postStop: .signalHandling(handleMessage: .ignore) { _, signal in
            p.tell("postStop")
            throw TestError.error
        })

        let ref = try system.spawnAnonymous(behavior)

        p.watch(ref)

        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }

    func test_makeAsynchronousCallback_shouldExecuteClosureInActorContext() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receive { context, msg in
            let cb = context.makeAsynchronousCallback {
                // This is a nasty trick to determine that the closure is
                // actually being executed in the context of the actor. After
                // calling the closure, it will check if the actor is still
                // supposed to run and if it's not, it will be stopped.
                context.myself._downcastUnsafe.cell.behavior = .stopped
                p.tell("fromCallback:\(msg)")
            }

            cb.invoke(())
            return .same
        }

        let ref = try system.spawnAnonymous(behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("fromCallback:test")
        try p.expectTerminated(ref)
    }
}
