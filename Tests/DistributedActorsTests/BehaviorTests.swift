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
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import Foundation
import NIO
import XCTest

class BehaviorTests: XCTestCase {
    var system: ActorSystem!
    var eventLoopGroup: EventLoopGroup!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        try! self.eventLoopGroup.syncShutdownGracefully()
    }

    public struct TestMessage {
        let message: String
        let replyTo: ActorRef<String>
    }

    func test_setup_executesImmediatelyOnStartOfActor() throws {
        let p = self.testKit.spawnTestProbe("testActor-1", expecting: String.self)

        let message = "EHLO"
        let _: ActorRef<String> = try system.spawn(.anonymous, .setup { _ in
            p.tell(message)
            return .stop
        })

        try p.expectMessage(message)
    }

    func test_single_actor_should_wakeUp_on_new_message_lockstep() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("testActor-2")

        var counter = 0

        for _ in 0 ... 10 {
            counter += 1
            let payload: String = "message-\(counter)"
            p.tell(payload)
            try p.expectMessage(payload)
        }
    }

    func test_two_actors_should_wakeUp_on_new_message_lockstep() throws {
        let p = self.testKit.spawnTestProbe("testActor-2", expecting: String.self)

        var counter = 0

        let echoPayload: ActorRef<TestMessage> =
            try system.spawn(.anonymous, .receiveMessage { message in
                p.tell(message.message)
                return .same
            })

        for _ in 0 ... 10 {
            counter += 1
            let payload: String = "message-\(counter)"
            echoPayload.tell(TestMessage(message: payload, replyTo: p.ref))
            try p.expectMessage(payload)
        }
    }

    func test_receive_shouldReceiveManyMessagesInExpectedOrder() throws {
        let p = self.testKit.spawnTestProbe("testActor-3", expecting: Int.self)

        func countTillNThenDieBehavior(n: Int, currentlyAt at: Int = -1) -> Behavior<Int> {
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
        let ref = try system.spawn("countTill\(n)", countTillNThenDieBehavior(n: n))

        // first we send many messages
        for i in 0 ... n {
            ref.tell(i)
        }

        // then we expect they arrive in the expected order
        for i in 0 ... n {
            try p.expectMessage(i)
        }
    }

    // TODO: another test with 2 senders, that either of their ordering is valid at recipient

    class MyActorBehavior: ClassBehavior<TestMessage> {
        public override func receive(context: ActorContext<TestMessage>, message: TestMessage) -> Behavior<TestMessage> {
            message.replyTo.tell(self.thxFor(message.message))
            return .same
        }

        func thxFor(_ m: String) -> String {
            return "Thanks for: <\(m)>"
        }
    }

    // has to be ClassBehavior in test name, otherwise our generate_linux_tests is confused (and thinks this is an inner class)
    func test_ClassBehavior_receivesMessages() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("testActor-5")

        let ref: ActorRef<TestMessage> = try system.spawn(.anonymous, .class { MyActorBehavior() })

        // first we send many messages
        for i in 0 ... 10 {
            ref.tell(TestMessage(message: "message-\(i)", replyTo: p.ref))
        }

        func thxFor(_ m: String) -> String {
            return "Thanks for: <\(m)>"
        }

        // separately see if we got the expected replies in the right order.
        // we do so separately to avoid sending in "lock-step" in the first loop above here
        for i in 0 ... 10 {
            try p.expectMessage(thxFor("message-\(i)"))
        }
    }

    class MySignalActorBehavior: ClassBehavior<String> {
        let probe: ActorRef<Signals.Terminated>

        init(probe: ActorRef<Signals.Terminated>) {
            self.probe = probe
        }

        public override func receive(context: ActorContext<String>, message: String) throws -> Behavior<String> {
            _ = try context.spawnWatch(.anonymous, Behavior<String>.stop)
            return .same
        }

        override func receiveSignal(context: ActorContext<String>, signal: Signal) -> Behavior<String> {
            if let terminated = signal as? Signals.Terminated {
                self.probe.tell(terminated)
            }
            return .same
        }
    }

    // has to be ClassBehavior in test name, otherwise our generate_linux_tests is confused (and thinks this is an inner class)
    func test_ClassBehavior_receivesSignals() throws {
        let p: ActorTestProbe<Signals.Terminated> = self.testKit.spawnTestProbe("probe-6a")
        let ref: ActorRef<String> = try system.spawn(.anonymous, .class { MySignalActorBehavior(probe: p.ref) })
        ref.tell("do it")

        _ = try p.expectMessage()
        // receiveSignal was invoked successfully
    }

    class MyStartingBehavior: ClassBehavior<String> {
        let probe: ActorRef<String>

        init(probe: ActorRef<String>) {
            self.probe = probe
            super.init()
            self.probe.tell("init")
        }

        public override func receive(context: ActorContext<String>, message: String) throws -> Behavior<String> {
            self.probe.tell("\(message)")
            throw TestError("Boom on purpose!")
        }
    }

    func test_ClassBehavior_executesInitOnStartSignal() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("probe-7a")
        let ref: ActorRef<String> = try system.spawn(
            .anonymous,
            props: .supervision(strategy: .restart(atMost: 1, within: nil)),
            .class { MyStartingBehavior(probe: p.ref) }
        )
        ref.tell("hello")

        try p.expectMessage("init")
        try p.expectMessage("hello")
        // restarts and executes init in new instance
        try p.expectMessage("init")
    }

    func test_receiveSpecificSignal_shouldReceiveAsExpected() throws {
        let p: ActorTestProbe<Signals.Terminated> = self.testKit.spawnTestProbe("probe-specificSignal-1")
        let _: ActorRef<String> = try system.spawn(.anonymous, .setup { context in
            let _: ActorRef<Never> = try context.spawnWatch(.anonymous, .stop)

            return .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                p.tell(terminated)
                return .stop
            }
        })

        _ = try p.expectMessage()
        // receiveSignalType was invoked successfully
    }

    func test_receiveSpecificSignal_shouldNotReceiveOtherSignals() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("probe-specificSignal-2")
        let ref: ActorRef<String> = try system.spawn(.anonymous, Behavior<String>.receiveMessage { _ in
            .stop
        }.receiveSpecificSignal(Signals.PostStop.self) { _, postStop in
            p.tell("got:\(postStop)")
            return .stop
        })
        ref.tell("please stop")

        try p.expectMessage("got:PostStop()")
        // receiveSignalType was invoked successfully
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
        return self.firstBehavior(probe).orElse(self.secondBehavior(probe))
    }

    func test_orElse_shouldExecuteFirstBehavior() throws {
        let p: ActorTestProbe<OrElseProtocol> = self.testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.first)
        try p.expectMessage(.first)
    }

    func test_orElse_shouldExecuteSecondBehavior() throws {
        let p: ActorTestProbe<OrElseProtocol> = self.testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.second)
        try p.expectMessage(.second)
    }

    func test_orElse_shouldNotExecuteSecondBehaviorOnIgnore() throws {
        let p: ActorTestProbe<OrElseProtocol> = self.testKit.spawnTestProbe()
        let ref: ActorRef<OrElseProtocol> = try system.spawn(.anonymous, self.combinedBehavior(p.ref))

        ref.tell(.other)
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_orElse_shouldProperlyHandleDeeplyNestedBehaviors() throws {
        let p: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        var behavior: Behavior<Int> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        for i in (0 ... 100).reversed() {
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

        ref.tell(50)
        try p.expectMessage(-50)

        p.tell(255)
        try p.expectMessage(255)
    }

    func test_orElse_shouldProperlyApplyTerminatedToSecondBehaviorBeforeCausingDeathPactError() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let first: Behavior<Never> = .setup { context in
            let child: ActorRef<String> = try context.spawnWatch("child", .receiveMessage { _ in
                throw TestError("Boom")
            })
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
        let second: Behavior<Never> = .receiveSignal { _, signal in
            switch signal {
            case let terminated as Signals.Terminated:
                p.tell("second:terminated-name:\(terminated.address.name)")
            default:
                ()
            }
            return .unhandled
        }
        let ref: ActorRef<Never> = try system.spawn("orElseTerminated", first.orElse(second))
        p.watch(ref)

        try p.expectMessage("first:terminated-name:child")
        try p.expectMessage("second:terminated-name:child")
        try p.expectTerminated(ref) // due to death pact, since none of the signal handlers handled Terminated
    }

    func test_orElse_shouldCanonicalizeNestedSetupInAlternative() throws {
        let p: ActorTestProbe<OrElseProtocol> = self.testKit.spawnTestProbe()

        let first: Behavior<OrElseProtocol> = .receiveMessage { _ in
            .unhandled
        }
        let second: Behavior<OrElseProtocol> = .setup { _ in
            p.tell(.second)
            return .setup { _ in
                p.tell(.second)
                return .receiveMessage { message in
                    p.tell(message)
                    return .unhandled
                }
            }
        }
        let ref: ActorRef<OrElseProtocol> = try system.spawn(.anonymous, first.orElse(second))

        ref.tell(.second)
        try p.expectMessage(.second)
        try p.expectMessage(.second)
        try p.expectMessage(.second)
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_stoppedWithPostStop_shouldTriggerPostStopCallback() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<Never> = .stop { _ in
            p.tell("postStop")
        }

        _ = try system.spawn(.anonymous, behavior)

        try p.expectMessage("postStop")
    }

    func test_stoppedWithPostStopThrows_shouldTerminate() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<Never> = .stop(postStop: .signalHandling(handleMessage: .ignore) { _, _ in
            p.tell("postStop")
            throw TestError("Boom")
        })

        let ref = try system.spawn(.anonymous, behavior)

        p.watch(ref)

        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }

    func test_makeAsynchronousCallback_shouldExecuteClosureInActorContext() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receive { context, msg in
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

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("fromCallback:test")
        try p.expectTerminated(ref)
    }

    func test_makeAsynchronousCallback_shouldPrintNicelyIfThrewInsideClosure() throws {
        let capture = LogCapture()
        let system = ActorSystem("CallbackCrash") { settings in
            settings.overrideLogger = .some(capture.makeLogger(label: "mock"))
        }
        defer {
            system.shutdown().wait()
        }

        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let mockLine = 77777

        let behavior: Behavior<String> = .receive { context, _ in
            let cb = context.makeAsynchronousCallback(line: UInt(mockLine)) {
                throw Boom("Oh no, what a boom!")
            }

            cb.invoke(())
            return .same
        }

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectTerminated(ref)

        try capture.shouldContain(message: "*Boom while interpreting [closure defined at*")
        try capture.shouldContain(message: "*BehaviorTests.swift:\(mockLine)*")
    }

    enum ContextClosureMessage {
        case context(() -> ActorRef<String>)
    }

    func test_myself_shouldStayValidAfterActorStopped() throws {
        let p: ActorTestProbe<ContextClosureMessage> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            p.tell(.context {
                context.myself
            })

            return .stop
        }

        let ref = try system.spawn("myselfStillValidAfterStopped", behavior)
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
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
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

        let ref = try system.spawn(.anonymous, behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref.sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("unsuspended:success(1)")
        try p.expectMessage("resumed:something else")
    }

    func test_suspendedActor_shouldStaySuspendedWhenResumeHandlerSuspendsAgain() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
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

        let ref = try system.spawn("suspender", behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref.sendSystemMessage(.resume(.success(1))) // actor will process the resume handler, but stay suspended
        try p.expectMessage("suspended:success(1)")
        try p.expectNoMessage(for: .milliseconds(50))

        ref.tell("last") // actor is still suspended and should not process this message
        try p.expectNoMessage(for: .milliseconds(50))

        ref.sendSystemMessage(.resume(.success("test")))

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
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .intercept(
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

        let ref = try system.spawn(.anonymous, behavior)

        ref.tell("something") // this message causes the actor the suspend

        try p.expectMessage("something")

        ref.tell("something else") // actor is suspended and should not process this message

        try p.expectNoMessage(for: .milliseconds(50))

        ref.sendSystemMessage(.resume(.failure(Boom())))

        try p.expectMessage().shouldStartWith(prefix: "unsuspended:Boom")
        try p.expectMessage("resumed:something else")
    }

    private func awaitResultBehavior(future: EventLoopFuture<Int>, timeout: DistributedActors.TimeAmount, probe: ActorTestProbe<String>? = nil, suspendProbe: ActorTestProbe<Result<Int, Error>>? = nil) -> Behavior<String> {
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

    private func awaitResultThrowingBehavior(future: EventLoopFuture<Int>, timeout: DistributedActors.TimeAmount, probe: ActorTestProbe<String>, suspendProbe: ActorTestProbe<Int>) -> Behavior<String> {
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
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Result<Int, Error>> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)

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
        let suspendProbe: ActorTestProbe<Result<Int, Error>> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)

        ref.tell("suspend")
        ref.tell("another test")
        try p.expectNoMessage(for: .milliseconds(10))
        try suspendProbe.expectNoMessage(for: .milliseconds(10))

        promise.fail(self.testKit.error())
        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error is CallSiteError else {
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
        let suspendProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)

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
        let suspendProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .seconds(1), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)
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
        let suspendProbe: ActorTestProbe<Result<Int, Error>> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)

        ref.tell("suspend")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error is TimeoutError else {
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
        let suspendProbe: ActorTestProbe<Result<Int, Error>> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

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

        let ref = try system.spawn(.anonymous, behavior)

        try p.expectMessage("initializing")
        ref.tell("while-suspended") // hits the actor while it's still suspended

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error is TimeoutError else {
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
        let suspendProbe: ActorTestProbe<Result<Int, Error>> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            p.tell("initializing")
            return context.awaitResult(of: future, timeout: .milliseconds(10)) { result in
                suspendProbe.tell(result)
                return .same
            }
        }

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        try p.expectMessage("initializing")

        let suspendResult = try suspendProbe.expectMessage()
        switch suspendResult {
        case .failure(let error):
            guard error is TimeoutError else {
                throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
            }
        default:
            throw p.error("Expected failure(ExecutionException(underlying: TimeoutError)), got \(suspendResult)")
        }

        try p.expectTerminated(ref)
    }

    func test_awaitResultThrowing_shouldCrashActorWhenFutureTimesOut() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let suspendProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = self.awaitResultThrowingBehavior(future: future, timeout: .milliseconds(10), probe: p, suspendProbe: suspendProbe)

        let ref = try system.spawn(.anonymous, behavior)
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
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receiveMessage { msg in
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

        let ref = try system.spawn(.anonymous, behavior)
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend

        ref.sendSystemMessage(.stop)

        try p.expectTerminated(ref)
    }

    func test_suspendedActor_shouldKeepProcessingSignals() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior = Behavior<String>.receive { context, msg in
            p.tell("suspended")
            _ = try context.spawnWatch("child", Behavior<String>.stop)
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
            return Behavior<String>.receiveMessage { msg in
                p.tell("changedBySignal:\(msg)")
                return .same
            }
        }

        let ref = try system.spawn("parent", behavior)

        ref.tell("something") // this message causes the actor to suspend
        try p.expectMessage("suspended")

        ref.tell("something else") // this message should not get processed until we resume, even though the behavior is changed by the signal

        try p.expectMessage("signal:child")

        ref.sendSystemMessage(.resume(.success(1)))

        try p.expectMessage("unsuspended:1")
        try p.expectMessage("changedBySignal:something else")
    }

    func test_suspendedActor_shouldStopWhenSignalHandlerReturnsStopped() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior = Behavior<String>.receive { context, msg in
            p.tell("suspended")
            _ = try context.spawnWatch("child", Behavior<String>.stop)
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

        let ref = try system.spawn("parent", behavior)
        p.watch(ref)

        ref.tell("something") // this message causes the actor the suspend
        try p.expectMessage("suspended")

        try p.expectTerminated(ref)
    }

    func test_onResultAsync_shouldExecuteContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
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

        _ = try system.spawn(.anonymous, behavior)

        promise.succeed(1)
        try probe.expectMessage(1)
    }

    func test_onResultAsync_shouldExecuteContinuationWhenFutureFails() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Error> = self.testKit.spawnTestProbe()
        let error = self.testKit.error()

        let behavior: Behavior<String> = .setup { context in
            context.onResultAsync(of: future, timeout: .milliseconds(300)) {
                switch $0 {
                case .success: throw self.testKit.error()
                case .failure(let error): probe.tell(error)
                }
                return .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)

        promise.fail(error)
        _ = try probe.expectMessage()
    }

    func test_onResultAsync_shouldAssignBehaviorFromContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let resultProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
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

        let ref = try system.spawn(.anonymous, behavior)

        promise.succeed(1)
        try resultProbe.expectMessage(1)

        ref.tell("test")
        try probe.expectMessage("assigned:test")
    }

    func test_onResultAsync_shouldCanonicalizeBehaviorFromContinuationWhenFutureSucceeds() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let resultProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
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

        _ = try system.spawn(.anonymous, behavior)

        promise.succeed(1)
        try resultProbe.expectMessage(1)

        try probe.expectMessage("setup")
    }

    func test_onResultAsync_shouldKeepProcessingMessagesWhileFutureIsNotCompleted() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let resultProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
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

        let ref = try system.spawn(.anonymous, behavior)

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
        let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let resultProbe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
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

        let ref = try system.spawn(.anonymous, behavior)

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
        let probe: ActorTestProbe<Int> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.onResultAsyncThrowing(of: future, timeout: .milliseconds(300)) {
                probe.tell($0)
                return .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)

        promise.succeed(1)
        try probe.expectMessage(1)
    }

    func test_onResultAsyncThrowing_shouldFailActorWhenFutureFails() throws {
        let eventLoop = self.eventLoopGroup.next()
        let promise: EventLoopPromise<Int> = eventLoop.makePromise()
        let future = promise.futureResult
        let probe: ActorTestProbe<Never> = self.testKit.spawnTestProbe()
        let error = self.testKit.error()

        let behavior: Behavior<String> = .setup { context in
            context.onResultAsyncThrowing(of: future, timeout: .milliseconds(300)) { _ in
                .same
            }

            return .receiveMessage { _ in
                .same
            }
        }

        let ref = try system.spawn(.anonymous, behavior)
        probe.watch(ref)

        promise.fail(error)
        try probe.expectTerminated(ref)
    }

    func test_ignore_shouldIgnoreAllIncomingMessages() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let behavior: Behavior<String> = .receiveMessage { message in
            p.tell("receive:\(message)")

            return .ignore // from now on, all messages will be ignored
        }

        let ref = try system.spawn(.anonymous, behavior)

        ref.tell("first")
        try p.expectMessage("receive:first")

        ref.tell("second")
        try p.expectNoMessage(for: .milliseconds(50))

        ref.tell("third")
        try p.expectNoMessage(for: .milliseconds(50))

        ref.tell("fourth")
        try p.expectNoMessage(for: .milliseconds(50))
    }
}
