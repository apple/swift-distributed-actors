//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import Foundation
import NIO
import XCTest

final class BehaviorTests: ActorSystemXCTestCase {
    public struct TestMessage: ActorMessage {
        let message: String
        let replyTo: _ActorRef<String>
    }

    func test_setup_executesImmediatelyOnStartOfActor() throws {
        let p = self.testKit.makeTestProbe("testActor-1", expecting: String.self)

        let message = "EHLO"
        let _: _ActorRef<String> = try system._spawn(
            .anonymous,
            .setup { _ in
                p.tell(message)
                return .stop
            }
        )

        try p.expectMessage(message)
    }

    func test_single_actor_should_wakeUp_on_new_message_lockstep() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe("testActor-2")

        var counter = 0

        for _ in 0 ... 10 {
            counter += 1
            let payload: String = "message-\(counter)"
            p.tell(payload)
            try p.expectMessage(payload)
        }
    }

    func test_two_actors_should_wakeUp_on_new_message_lockstep() throws {
        let p = self.testKit.makeTestProbe("testActor-2", expecting: String.self)

        var counter = 0

        let echoPayload: _ActorRef<TestMessage> =
            try system._spawn(
                .anonymous,
                .receiveMessage { message in
                    p.tell(message.message)
                    return .same
                }
            )

        for _ in 0 ... 10 {
            counter += 1
            let payload: String = "message-\(counter)"
            echoPayload.tell(TestMessage(message: payload, replyTo: p.ref))
            try p.expectMessage(payload)
        }
    }

    func test_receive_shouldReceiveManyMessagesInExpectedOrder() throws {
        let p = self.testKit.makeTestProbe("testActor-3", expecting: Int.self)

        func countTillNThenDieBehavior(n: Int, currentlyAt at: Int = -1) -> _Behavior<Int> {
            if at == n {
                return .setup { _ in
                    .stop
                }
            } else {
                return .receive { _, message in
                    if message == at + 1 {
                        p.tell(message)
                        return countTillNThenDieBehavior(n: n, currentlyAt: message)
                    } else {
                        fatalError("Received \(message) when was expecting \(at + 1)! Ordering rule violated.")
                    }
                }
            }
        }

        let n = 10
        let ref = try system._spawn("countTill\(n)", countTillNThenDieBehavior(n: n))

        // first we send many messages
        for i in 0 ... n {
            ref.tell(i)
        }

        // then we expect they arrive in the expected order
        for i in 0 ... n {
            try p.expectMessage(i)
        }
    }

    func test_receiveSpecificSignal_shouldReceiveAsExpected() throws {
        let p: ActorTestProbe<Signals.Terminated> = self.testKit.makeTestProbe("probe-specificSignal-1")
        let _: _ActorRef<String> = try system._spawn(
            .anonymous,
            .setup { context in
                let _: _ActorRef<Never> = try context._spawnWatch(.anonymous, .stop)

                return .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                    p.tell(terminated)
                    return .stop
                }
            }
        )

        _ = try p.expectMessage()
        // receiveSignalType was invoked successfully
    }

    func test_receiveSpecificSignal_shouldNotReceiveOtherSignals() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe("probe-specificSignal-2")
        let ref: _ActorRef<String> = try system._spawn(
            .anonymous,
            _Behavior<String>.receiveMessage { _ in
                .stop
            }.receiveSpecificSignal(Signals._PostStop.self) { _, postStop in
                p.tell("got:\(postStop)")
                return .stop
            }
        )
        ref.tell("please stop")

        try p.expectMessage("got:_PostStop()")
        // receiveSignalType was invoked successfully
    }

    enum OrElseMessage: String, ActorMessage {
        case first
        case second
        case other
    }

    func firstBehavior(_ probe: _ActorRef<OrElseMessage>) -> _Behavior<OrElseMessage> {
        .receiveMessage { message in
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

    func secondBehavior(_ probe: _ActorRef<OrElseMessage>) -> _Behavior<OrElseMessage> {
        .receiveMessage { message in
            probe.tell(message)
            return .same
        }
    }

    func combinedBehavior(_ probe: _ActorRef<OrElseMessage>) -> _Behavior<OrElseMessage> {
        self.firstBehavior(probe).orElse(self.secondBehavior(probe))
    }

    func test_orElse_shouldExecuteFirstBehavior() throws {
        let p: ActorTestProbe<OrElseMessage> = self.testKit.makeTestProbe()
        let ref: _ActorRef<OrElseMessage> = try system._spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.first)
        try p.expectMessage(.first)
    }

    func test_orElse_shouldExecuteSecondBehavior() throws {
        let p: ActorTestProbe<OrElseMessage> = self.testKit.makeTestProbe()
        let ref: _ActorRef<OrElseMessage> = try system._spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.second)
        try p.expectMessage(.second)
    }

    func test_orElse_shouldNotExecuteSecondBehaviorOnIgnore() throws {
        let p: ActorTestProbe<OrElseMessage> = self.testKit.makeTestProbe()
        let ref: _ActorRef<OrElseMessage> = try system._spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.other)
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_orElse_shouldProperlyHandleDeeplyNestedBehaviors() throws {
        let p: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        var behavior: _Behavior<Int> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        for i in (0 ... 100).reversed() {
            behavior = _Behavior<Int>.receiveMessage { message in
                if message == i {
                    p.tell(-i)
                    return .same
                } else {
                    return .unhandled
                }
            }.orElse(behavior)
        }

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell(50)
        try p.expectMessage(-50)

        p.tell(255)
        try p.expectMessage(255)
    }

    func test_orElse_shouldProperlyApplyTerminatedToSecondBehaviorBeforeCausingDeathPactError() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let first: _Behavior<Never> = .setup { context in
            let child: _ActorRef<String> = try context._spawnWatch(
                "child",
                .receiveMessage { _ in
                    throw TestError("Boom")
                }
            )
            child.tell("Please throw now.")

            return .receiveSignal { _, signal in
                switch signal {
                case let terminated as Signals.Terminated:
                    p.tell("first:terminated-name:\(terminated.address.name)")
                default:
                    ()
                }
                return .unhandled
            }
        }
        let second: _Behavior<Never> = .receiveSignal { _, signal in
            switch signal {
            case let terminated as Signals.Terminated:
                p.tell("second:terminated-name:\(terminated.address.name)")
            default:
                ()
            }
            return .unhandled
        }
        let ref: _ActorRef<Never> = try system._spawn("orElseTerminated", first.orElse(second))
        p.watch(ref)

        try p.expectMessage("first:terminated-name:child")
        try p.expectMessage("second:terminated-name:child")
        try p.expectTerminated(ref) // due to death pact, since none of the signal handlers handled Terminated
    }

    func test_orElse_shouldCanonicalizeNestedSetupInAlternative() throws {
        let p: ActorTestProbe<OrElseMessage> = self.testKit.makeTestProbe()

        let first: _Behavior<OrElseMessage> = .receiveMessage { _ in
            .unhandled
        }
        let second: _Behavior<OrElseMessage> = .setup { _ in
            p.tell(.second)
            return .setup { _ in
                p.tell(.second)
                return .receiveMessage { message in
                    p.tell(message)
                    return .unhandled
                }
            }
        }
        let ref: _ActorRef<OrElseMessage> = try system._spawn(.anonymous, first.orElse(second))

        ref.tell(.second)
        try p.expectMessage(.second)
        try p.expectMessage(.second)
        try p.expectMessage(.second)
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_stoppedWithPostStop_shouldTriggerPostStopCallback() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<Never> = .stop { _ in
            p.tell("postStop")
        }

        try system._spawn(.anonymous, behavior)

        try p.expectMessage("postStop")
    }

    func test_stoppedWithPostStopThrows_shouldTerminate() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<Never> = .stop(
            postStop: .signalHandling(handleMessage: .ignore) { _, _ in
                p.tell("postStop")
                throw TestError("Boom")
            }
        )

        let ref = try system._spawn(.anonymous, behavior)

        p.watch(ref)

        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }

    func test_makeAsynchronousCallback_shouldExecuteClosureInActorContext() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .receive { context, msg in
            let cb = context.makeAsynchronousCallback {
                // This is a nasty trick to determine that the closure is
                // actually being executed in the context of the actor. After
                // calling the closure, it will check if the actor is still
                // supposed to run and if it's not, it will be stopped.
                context.myself._unsafeUnwrapCell.actor?.behavior = .stop
                p.tell("fromCallback:\(msg)")
            }

            cb.invoke(())
            return .same
        }

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("fromCallback:test")
        try p.expectTerminated(ref)
    }

    func test_makeAsynchronousCallback_shouldPrintNicelyIfThrewInsideClosure() async throws {
        let capture = LogCapture(settings: .init())
        let system = await ActorSystem("CallbackCrash") { settings in
            settings.logging.baseLogger = capture.logger(label: "mock")
        }
        defer {
            try! system.shutdown().wait()
        }

        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let mockLine = 77777

        let behavior: _Behavior<String> = .receive { context, _ in
            let cb = context.makeAsynchronousCallback(line: UInt(mockLine)) {
                throw Boom("Oh no, what a boom!")
            }

            cb.invoke(())
            return .same
        }

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectTerminated(ref)

        try capture.shouldContain(message: "*Boom while interpreting [closure defined at*")
        try capture.shouldContain(message: "*BehaviorTests.swift:\(mockLine)*")
    }

    enum ContextClosureMessage: NonTransportableActorMessage {
        case context(() -> _ActorRef<String>)
    }

    func test_myself_shouldStayValidAfterActorStopped() throws {
        let p: ActorTestProbe<ContextClosureMessage> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            p.tell(.context {
                context.myself
            })

            return .stop
        }

        let ref = try system._spawn("myselfStillValidAfterStopped", behavior)
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
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                .suspend { (msg: Result<Int, Error>) in
                    p.tell("unsuspended:\(msg)")
                    return .receiveMessage { msg in
                        p.tell("resumed:\(msg)")
                        return .same
                    }
                }
            },
            with: ProbeInterceptor(probe: p)
        )

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref._sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("unsuspended:success(1)")
        try p.expectMessage("resumed:something else")
    }

    func test_suspendedActor_shouldStaySuspendedWhenResumeHandlerSuspendsAgain() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                .suspend { (msg: Result<Int, Error>) in
                    p.tell("suspended:\(msg)")
                    return .suspend { (msg: Result<String, Error>) in
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

        let ref = try system._spawn("suspender", behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref._sendSystemMessage(.resume(.success(1))) // actor will process the resume handler, but stay suspended
        try p.expectMessage("suspended:success(1)")
        try p.expectNoMessage(for: .milliseconds(50))

        ref.tell("last") // actor is still suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref._sendSystemMessage(.resume(.success("test")))

        try p.expectMessage("unsuspended:success(\"test\")")
        try p.expectMessage("resumed:something else")
        try p.expectMessage("resumed:last")
    }

    struct Boom: Error {
        let message: String
        init(_ message: String = "") {
            self.message = message
        }
    }

    func test_suspendedActor_shouldBeUnsuspendedOnFailedResumeSystemMessage() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .intercept(
            behavior: .receiveMessage { msg in
                .suspend { (msg: Result<Int, Error>) in
                    switch msg {
                    case .success(let res): p.tell("unsuspended:\(res)")
                    case .failure(let error): p.tell("unsuspended:\(error)")
                    }
                    return .receiveMessage { msg in
                        p.tell("resumed:\(msg)")
                        return .same
                    }
                }
            },
            with: ProbeInterceptor(probe: p)
        )

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref._sendSystemMessage(.resume(.failure(Boom())))

        try p.expectMessage().shouldStartWith(prefix: "unsuspended:Boom")
        try p.expectMessage("resumed:something else")
    }

    private func awaitResultBehavior(future: EventLoopFuture<Int>, timeout: DistributedActors.TimeAmount, probe: ActorTestProbe<String>? = nil, suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>>? = nil) -> _Behavior<String> {
        .receive { context, message in
            switch message {
            case "suspend":
                return context.awaitResult(of: future, timeout: timeout) { result in
                    suspendProbe?.tell(result.mapError { error in ErrorEnvelope(error) })
                    return .same
                }
            default:
                probe?.tell(message)
                return .same
            }
        }
    }

    private func awaitResultThrowingBehavior(future: EventLoopFuture<Int>, timeout: DistributedActors.TimeAmount, probe: ActorTestProbe<String>, suspendProbe: ActorTestProbe<Int>) -> _Behavior<String> {
        .receive { context, message in
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
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)

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
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("suspend")
        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.fail(self.testKit.error())
        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let errorEnvelope):
            guard let error = errorEnvelope.error as? BestEffortStringError, error.representation.contains("\(String(reflecting: CallSiteError.self))") else {
                throw p.error("Expected failure(ExecutionException(underlying: CallSiteError())), got \(suspendResult)")
            }
        default: throw p.error("Expected failure(ExecutionException(underlying: CallSiteError())), got \(suspendResult)")
        }

        try p.expectMessage("another test")
    }

    func test_awaitResultThrowing_shouldResumeActorSuccessResultWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)

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
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("test")

        ref.tell("suspend")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.fail(self.testKit.error())
        try suspendProbe.expectNoMessage(for: .milliseconds(10))
        try p.expectTerminated(ref)
    }

    func test_awaitResult_shouldResumeActorWithFailureResultWhenFutureTimesOut() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("suspend")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let errorEnvelope):
            guard let error = errorEnvelope.error as? BestEffortStringError, error.representation.contains("\(String(reflecting: TimeoutError.self))") else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default: throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        ref.tell("test")
        try p.expectMessage("test")
    }

    func test_awaitResult_shouldWorkWhenReturnedInsideInitialSetup() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            p.tell("initializing")
            return context.awaitResult(of: future, timeout: .milliseconds(100)) { result in
                suspendProbe.tell(result.mapError { error in ErrorEnvelope(error) })
                return .receiveMessage { message in
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system._spawn(.anonymous, behavior)

        try p.expectMessage("initializing")
        ref.tell("while-suspended") // hits the actor while it's still suspended

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let errorEnvelope):
            guard let error = errorEnvelope.error as? BestEffortStringError, error.representation.contains("\(String(reflecting: TimeoutError.self))") else {
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
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            p.tell("initializing")
            return context.awaitResult(of: future, timeout: .milliseconds(10)) { result in
                suspendProbe.tell(result.mapError { error in ErrorEnvelope(error) })
                return .same
            }
        }

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)

        try p.expectMessage("initializing")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let errorEnvelope):
            guard let error = errorEnvelope.error as? BestEffortStringError, error.representation.contains("\(String(reflecting: TimeoutError.self))") else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default:
            throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        try p.expectTerminated(ref)
    }

    func test_awaitResult_allowBecomingIntoSetup() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, ErrorEnvelope>> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            p.tell("initializing")
            return .receiveMessage { _ in
                context.awaitResult(of: future, timeout: .seconds(3)) { result in
                    .setup { _ in
                        suspendProbe.tell(result.mapError { error in ErrorEnvelope(error) })
                        return .same
                    }
                }
            }
        }

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)
        try p.expectMessage("initializing")

        ref.tell("wake up")
        promise.succeed(13)

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .success(let value):
            value.shouldEqual(13)
        default:
            throw p.error("Expected success, got \(suspendResult)")
        }
    }

    func test_awaitResultThrowing_shouldCrashActorWhenFutureTimesOut() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system._spawn(.anonymous, behavior)
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
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .receiveMessage { msg in
            .suspend { (msg: Result<Int, Error>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error)")
                }
                return .receiveMessage { msg in
                    p.tell("resumed:\(msg)")
                    return .same
                }
            }
        }

        let ref = try system._spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend

        ref._sendSystemMessage(.stop)

        try p.expectTerminated(ref)
    }

    func test_suspendedActor_shouldKeepProcessingSignals() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior = _Behavior<String>.receive { context, msg in
            p.tell("suspended")
            try context._spawnWatch("child", _Behavior<String>.stop)
            return .suspend { (msg: Result<Int, Error>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error)")
                }
                return .same
            }
        }.receiveSignal { _, signal in
            guard let s = signal as? Signals.Terminated else {
                return .same
            }
            p.tell("signal:\(s.address.name)")

            // returning this behavior should not unsuspend the actor
            return _Behavior<String>.receiveMessage { msg in
                p.tell("changedBySignal:\(msg)")
                return .same
            }
        }

        let ref = try system._spawn("parent", behavior)

        ref.tell("something") // this message causes the actor to suspend
        try p.expectMessage("suspended")

        ref.tell("something else") // this message should not get processed until we resume, even though the behavior is changed by the signal

        try p.expectMessage("signal:child")

        ref._sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("unsuspended:1")
        try p.expectMessage("changedBySignal:something else")
    }

    func test_suspendedActor_shouldStopWhenSignalHandlerReturnsStopped() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior = _Behavior<String>.receive { context, msg in
            p.tell("suspended")
            try context._spawnWatch("child", _Behavior<String>.stop)
            return .suspend { (msg: Result<Int, Error>) in
                switch msg {
                case .success(let res): p.tell("unsuspended:\(res)")
                case .failure(let error): p.tell("unsuspended:\(error)")
                }
                return .same
            }
        }.receiveSignal { _, _ in
            .stop
        }

        let ref = try system._spawn("parent", behavior)
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend
        try p.expectMessage("suspended")

        try p.expectTerminated(ref)
    }

    func test_onResultAsync_shouldExecuteContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .milliseconds(300)) {
                switch $0 {
                case .success(let res): probe.tell(res)
                case .failure(let error): throw error
                }
                return .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        try system._spawn(.anonymous, behavior)

        promise.succeed(1)
        try probe.expectMessage(1)
    }

    func test_onResultAsync_shouldExecuteContinuationWhenFutureFails() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe = self.testKit.makeTestProbe(expecting: NonTransportableAnyError.self)
        let error = self.testKit.error()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .milliseconds(300)) {
                switch $0 {
                case .success: throw self.testKit.error()
                case .failure(let error): probe.tell(.init(error))
                }
                return .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        try system._spawn(.anonymous, behavior)

        promise.fail(error)
        _ = try probe.expectMessage()
    }

    func test_onResultAsync_shouldAssignBehaviorFromContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let resultProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .milliseconds(300)) {
                switch $0 {
                case .success(let res): resultProbe.tell(res)
                case .failure(let error): throw error
                }
                return .receiveMessage {
                    probe.tell("assigned:\($0)")
                    return .same
                }
            }

            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref = try system._spawn(.anonymous, behavior)

        promise.succeed(1)
        try resultProbe.expectMessage(1)

        ref.tell("test")
        try probe.expectMessage("assigned:test")
    }

    func test_onResultAsync_shouldCanonicalizeBehaviorFromContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let resultProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .milliseconds(300)) {
                switch $0 {
                case .success(let res): resultProbe.tell(res)
                case .failure(let error): throw error
                }
                return .setup { _ in
                    probe.tell("setup")
                    return .receiveMessage { _ in
                        .same
                    }
                }
            }

            return .receiveMessage { _ in
                .same
            }
        }

        try system._spawn(.anonymous, behavior)

        promise.succeed(1)
        try resultProbe.expectMessage(1)

        try probe.expectMessage("setup")
    }

    func test_onResultAsync_shouldKeepProcessingMessagesWhileFutureIsNotCompleted() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let resultProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .seconds(3)) {
                switch $0 {
                case .success(let res): resultProbe.tell(res)
                case .failure(let error): throw error
                }
                return .same
            }

            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("test")
        try probe.expectMessage("started:test")

        ref.tell("test2")
        try probe.expectMessage("started:test2")

        promise.succeed(1)
        try resultProbe.expectMessage(1)
    }

    func test_onResultAsync_shouldAllowChangingBehaviorWhileFutureIsNotCompleted() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let resultProbe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .seconds(3)) {
                switch $0 {
                case .success(let res): resultProbe.tell(res)
                case .failure(let error): throw error
                }
                return .receiveMessage {
                    probe.tell("assigned:\($0)")
                    return .same
                }
            }

            return .receiveMessage {
                probe.tell("started:\($0)")
                return .receiveMessage {
                    probe.tell("changed:\($0)")
                    return .same
                }
            }
        }

        let ref = try system._spawn(.anonymous, behavior)

        ref.tell("test")
        try probe.expectMessage("started:test")

        ref.tell("test")
        try probe.expectMessage("changed:test")

        promise.succeed(1)
        try resultProbe.expectMessage(1)

        ref.tell("test")
        try probe.expectMessage("assigned:test")
    }

    func test_onResultAsyncThrowing_shouldExecuteContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsyncThrowing(of: future, timeout: .milliseconds(300)) {
                probe.tell($0)
                return .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        try system._spawn(.anonymous, behavior)

        promise.succeed(1)
        try probe.expectMessage(1)
    }

    func test_onResultAsyncThrowing_shouldFailActorWhenFutureFails() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Never> = self.testKit.makeTestProbe()
        let error = self.testKit.error()

        let behavior: _Behavior<String> = .setup { context in
            context.onResultAsyncThrowing(of: future, timeout: .milliseconds(300)) { _ in
                .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        let ref = try system._spawn(.anonymous, behavior)
        probe.watch(ref)

        promise.fail(error)
        try probe.expectTerminated(ref)
    }
}
