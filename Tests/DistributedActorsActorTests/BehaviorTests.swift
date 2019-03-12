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

class BehaviorTests: XCTestCase {

    let system = ActorSystem("BehaviorTests")
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
        try! eventLoopGroup.syncShutdownGracefully()
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
                context.myself._downcastUnsafe.cell?.behavior = .stopped
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

    enum ContextClosureMessage {
        case context(() -> ActorRef<String>)
    }

    func test_myself_shouldStayValidAfterActorStopped() throws {
        let p: ActorTestProbe<ContextClosureMessage> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            p.tell(.context {
                return context.myself
            })

            return .stopped
        }

        let ref = try system.spawn(behavior, name: "myselfStillValidAfterStopped")
        p.watch(ref)

        ref.tell("test") // this does nothing
        try p.expectTerminated(ref)
        switch try p.expectMessage() {
        case .context(let closure):
            let ref2 = closure()
            ref.shouldEqual(ref2)
        }
    }

    func test_suspendedActor_shouldBeUnsuspendedOnResumeSystemMessage() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                return .suspend { (msg: Result<Int, ExecutionError>) in
                    p.tell("unsuspended:\(msg)")
                    return .receiveMessage { msg in
                        p.tell("resumed:\(msg)")
                        return .same
                    }
                }
            },
            with: ProbeInterceptor(probe: p)
        )

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref._downcastUnsafe.sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("unsuspended:success(1)")
        try p.expectMessage("resumed:something else")
    }

    func test_suspendedActor_shouldStaySuspendedWhenResumeHandlerSuspendsAgain() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                return .suspend { (msg: Result<Int, ExecutionError>) in
                    p.tell("suspended:\(msg)")
                    return .suspend { (msg: Result<String, ExecutionError>) in
                        p.tell("unsuspended:\(msg)")
                        return .receiveMessage { msg in
                            p.tell("resumed:\(msg)")
                            return .same
                        }
                    }
                }
            },
            with: ProbeInterceptor(probe: p)
        )

        let ref = try system.spawn(behavior, name: "suspender")

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref._downcastUnsafe.sendSystemMessage(.resume(.success(1))) // actor will process the resume handler, but stay suspended
        try p.expectMessage("suspended:success(1)")
        try p.expectNoMessage(for: .milliseconds(50))

        ref.tell("last") // actor is still suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref._downcastUnsafe.sendSystemMessage(.resume(.success("test")))

        try p.expectMessage("unsuspended:success(\"test\")")
        try p.expectMessage("resumed:something else")
        try p.expectMessage("resumed:last")
    }

    enum Boom: Error {
        case boom
    }

    func test_suspendedActor_shouldBeUnsuspendedOnFailedResumeSystemMessage() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                return .suspend { (msg: Result<Int, ExecutionError>) in
                    switch msg {
                    case .success(let res): p.tell("unsuspended:\(res)")
                    case .failure(let error): p.tell("unsuspended:\(error.underlying)")
                    }
                    return .receiveMessage { msg in
                        p.tell("resumed:\(msg)")
                        return .same
                    }
                }
            },
            with: ProbeInterceptor(probe: p)
        )

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref._downcastUnsafe.sendSystemMessage(.resume(.failure(ExecutionError(underlying: Boom.boom))))

        try p.expectMessage("unsuspended:boom")
        try p.expectMessage("resumed:something else")
    }

    private func awaitResultBehavior(future: EventLoopFuture<Int>, timeout: Swift Distributed ActorsActor.TimeAmount, probe: ActorTestProbe<String>? = nil, suspendProbe: ActorTestProbe<Result<Int, ExecutionError>>? = nil) -> Behavior<String> {
        return .receive { context, message in
            switch message {
            case "suspend":
                return context.awaitResult(of: future, timeout: timeout) {
                    suspendProbe?.tell($0)
                    return .same
                }
            default:
                probe?.tell(message)
                return .same
            }
        }
    }

    private func awaitResultThrowingBehavior(future: EventLoopFuture<Int>, timeout: Swift Distributed ActorsActor.TimeAmount, probe: ActorTestProbe<String>, suspendProbe: ActorTestProbe<Int>) -> Behavior<String> {
        return .receive { context, message in
            switch message {
            case "suspend":
                return context.awaitResultThrowing(of: future, timeout: timeout) {
                    suspendProbe.tell($0)
                    return .same
                }
            default:
                probe.tell(message)
                return .same
            }
        }
    }

    func test_awaitResult_shouldResumeActorWithSuccessResultWhenFutureSucceeds() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ExecutionError>> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("test")
        try p.expectMessage("test")

        ref.tell("suspend")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.succeed(1)
        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .success(1): ()
        default: XCTFail("Expected success(1), got \(suspendResult)")
        }

        try p.expectMessage("another test")
    }

    func test_awaitResult_shouldResumeActorWithFailureResultWhenFutureFails() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ExecutionError>> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("suspend")
        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.fail(Boom.boom)
        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard case Boom.boom = error.underlying else {
                throw p.error("Expected failure(ExecutionException(underlying: Boom.boom)), got \(suspendResult)")
            }
        default: throw p.error("Expected failure(ExecutionException(underlying: Boom.boom)), got \(suspendResult)")
        }

        try p.expectMessage("another test")
    }

    func test_awaitResultThrowing_shouldResumeActorSuccessResultWhenFutureSucceeds() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("test")
        try p.expectMessage("test")

        ref.tell("suspend")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.succeed(1)
        try suspendProbe.expectMessage(1)
        try p.expectMessage("another test")
    }

    func test_awaitResultThrowing_shouldCrashActorWhenFutureFails() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("test")

        ref.tell("suspend")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.fail(Boom.boom)
        try suspendProbe.expectNoMessage(for: .milliseconds(10))
        try p.expectTerminated(ref)
    }

    func test_awaitResult_shouldResumeActorWithFailureResultWhenFutureTimesOut() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ExecutionError>> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)

        ref.tell("suspend")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error.underlying is TimeoutError else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default: throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        ref.tell("test")
        try p.expectMessage("test")
    }

    func test_awaitResult_shouldWorkWhenReturnedInsideInitialSetup() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ExecutionError>> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in 
            p.tell("initializing")
            return context.awaitResult(of: future, timeout: .milliseconds(100)) { result in
                suspendProbe.tell(result)
                return .receiveMessage { message in
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior)

        try p.expectMessage("initializing")
        ref.tell("while-suspended") // hits the actor while it's still suspended

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error.underlying is TimeoutError else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default: 
            throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        try p.expectMessage("while-suspended")

        ref.tell("test")
        try p.expectMessage("test")
    }

    func test_awaitResult_shouldCrashWhenReturnedInsideInitialSetup_andReturnSameOnResume() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ExecutionError>> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            p.tell("initializing")
            return context.awaitResult(of: future, timeout: .milliseconds(10)) { result in
                suspendProbe.tell(result)
                return .same
            }
        }

        let ref = try system.spawnAnonymous(behavior)
        p.watch(ref)

        try p.expectMessage("initializing")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error.underlying is TimeoutError else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default:
            throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        try p.expectTerminated(ref)
    }

    func test_awaitResultThrowing_shouldCrashActorWhenFutureTimesOut() throws {
        let eventLoop = eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = awaitResultThrowingBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawnAnonymous(behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("test")

        ref.tell("suspend")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        try p.expectTerminated(ref)
    }

    func test_suspendedActor_shouldKeepProcessingSystemMessages() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receiveMessage { msg in
            return .suspend { (msg: Result<Int, ExecutionError>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error.underlying)")
                }
                return .receiveMessage { msg in
                    p.tell("resumed:\(msg)")
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior)
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend

        ref._downcastUnsafe.sendSystemMessage(.stop)

        try p.expectTerminated(ref)
    }

    func test_suspendedActor_shouldKeepProcessingSignals() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior = Behavior<String>.receive { context, msg in
            p.tell("suspended")
            _ = try context.spawnWatched(Behavior<String>.stopped, name: "child")
            return .suspend { (msg: Result<Int, ExecutionError>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error.underlying)")
                }
                return .same
            }
        }.receiveSignal { context, signal in
            guard let s = signal as? Signals.Terminated else {
                return .same
            }
            p.tell("signal:\(s.path.name)")

            // returning this behavior should not unsuspend the actor
            return Behavior<String>.receiveMessage { msg in
                p.tell("changedBySignal:\(msg)")
                return .same
            }
        }

        let ref = try system.spawn(behavior, name: "parent")

        ref.tell("something") // this message causes the actor the suspend
        try p.expectMessage("suspended")

        ref.tell("something else") // this message should not get processed until we resume, even though the behavior is changed by the signal
        ref._downcastUnsafe.sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("signal:child")
        try p.expectMessage("unsuspended:1")
        try p.expectMessage("changedBySignal:something else")
    }

    func test_suspendedActor_shouldStopWhenSignalHandlerReturnsStopped() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior = Behavior<String>.receive { context, msg in
            p.tell("suspended")
            _ = try context.spawnWatched(Behavior<String>.stopped, name: "child")
            return .suspend { (msg: Result<Int, ExecutionError>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error.underlying)")
                }
                return .same
            }
        }.receiveSignal { context, signal in
            return .stopped
        }

        let ref = try system.spawn(behavior, name: "parent")
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend
        try p.expectMessage("suspended")

        try p.expectTerminated(ref)
    }
}
