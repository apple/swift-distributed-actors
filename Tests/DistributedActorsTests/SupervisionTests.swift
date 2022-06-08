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
import NIO
import XCTest

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

final class SupervisionTests: ClusterSystemXCTestCase {
    enum FaultyError: Error, NotActuallyCodableMessage {
        case boom(message: String)
    }

    enum FaultyMessage: NotActuallyCodableMessage {
        case pleaseThrow(error: Error)
        case echo(message: String, replyTo: _ActorRef<WorkerMessages>)
        case pleaseFailAwaiting(message: String)
    }

    enum SimpleProbeMessages: Equatable, NotActuallyCodableMessage {
        case spawned(child: _ActorRef<FaultyMessage>)
        case echoing(message: String)
    }

    enum WorkerMessages: Equatable, NotActuallyCodableMessage {
        case setupRunning(ref: _ActorRef<FaultyMessage>)
        case echo(message: String)
    }

    enum FailureMode: NotActuallyCodableMessage {
        case throwing
        // case faulting // Not implemented

        func fail() throws {
            switch self {
            // case .faulting: fatalError("SIGNAL_BOOM") // not implemented
            case .throwing: throw FaultyError.boom(message: "SIGNAL_BOOM")
            }
        }
    }

    func faulty(probe: _ActorRef<WorkerMessages>?) -> _Behavior<FaultyMessage> {
        .setup { context in
            probe?.tell(.setupRunning(ref: context.myself))

            return .receiveMessage {
                switch $0 {
                case .pleaseThrow(let error):
                    throw error
                case .echo(let msg, let sender):
                    sender.tell(.echo(message: "echo:\(msg)"))
                    return .same
                case .pleaseFailAwaiting(let msg):
                    let failed: EventLoopFuture<String> = context.system._eventLoopGroup.next().makeFailedFuture(Boom("Failed: \(msg)"))
                    return context.awaitResultThrowing(of: failed, timeout: .seconds(1)) { _ in
                        .same
                    }
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Shared test implementation, which is to run with either error/fault causing messages

    func sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = self.testKit.makeTestProbe(expecting: WorkerMessages.self)
        let pp = self.testKit.makeTestProbe(expecting: Never.self)

        let parentBehavior: _Behavior<Never> = .setup { context in
            let strategy: _SupervisionStrategy = .stop
            let behavior = self.faulty(probe: p.ref)
            let _: _ActorRef<FaultyMessage> = try context._spawn(
                "\(runName)-erroring-1",
                props: .supervision(strategy: strategy),
                behavior
            )
            return .same
        }
        let interceptedParent = pp.interceptAllMessages(sentTo: parentBehavior) // TODO: intercept not needed

        let parent: _ActorRef<Never> = try system._spawn("\(runName)-parent", interceptedParent)

        guard case .setupRunning(let faultyWorker) = try p.expectMessage() else { throw p.error() }

        p.watch(faultyWorker)
        faultyWorker.tell(makeEvilMessage("Boom"))

        // it should have stopped on the failure
        try p.expectTerminated(faultyWorker)

        // meaning that the .stop did not accidentally also cause the parent to die
        // after all, it dod NOT watch the faulty actor, so death pact also does not come into play
        pp.watch(parent)
        try pp.expectNoTerminationSignal(for: .milliseconds(100))
    }

    func sharedTestLogic_restartSupervised_shouldRestart(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = self.testKit.makeTestProbe(expecting: WorkerMessages.self)
        let pp = self.testKit.makeTestProbe(expecting: Never.self)

        let parentBehavior: _Behavior<Never> = .setup { context in
            let _: _ActorRef<FaultyMessage> = try context._spawn(
                "\(runName)-erroring-2",
                props: _Props().supervision(strategy: .restart(atMost: 2, within: .seconds(1))),
                self.faulty(probe: p.ref)
            )

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: _ActorRef<Never> = try system._spawn("\(runName)-parent-2", behavior)
        pp.watch(parent)

        guard case .setupRunning(let faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate

        pinfo("Now expecting it to run setup again...")
        guard case .setupRunning(let faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }

        // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
        faultyWorkerRestarted.shouldEqual(faultyWorker)

        pinfo("Not expecting a reply from it")
        faultyWorker.tell(.echo(message: "two", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:two"))

        faultyWorker.tell(makeEvilMessage("Boom: 2nd (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300))

        pinfo("Now it boomed but did not crash again!")
    }

    func sharedTestLogic_restartSupervised_shouldRestartWithConstantBackoff(
        runName: String,
        makeEvilMessage: @escaping (String) -> FaultyMessage
    ) throws {
        let backoff = Backoff.constant(.milliseconds(200))

        let p = self.testKit.makeTestProbe(expecting: WorkerMessages.self)
        let pp = self.testKit.makeTestProbe(expecting: Never.self)

        let parentBehavior: _Behavior<Never> = .setup { context in
            let _: _ActorRef<FaultyMessage> = try context._spawn(
                "\(runName)-failing-2",
                props: _Props().supervision(strategy: .restart(atMost: 3, within: .seconds(1), backoff: backoff)),
                self.faulty(probe: p.ref)
            )

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: _ActorRef<Never> = try system._spawn("\(runName)-parent-2", behavior)
        pp.watch(parent)

        guard case .setupRunning(let faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        func boomExpectBackoffRestart(expectedBackoff: DistributedActors.TimeAmount) throws {
            // confirm it is alive and working
            faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
            try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

            pinfo("make it crash")
            // make it crash
            faultyWorker.tell(makeEvilMessage("Boom: (\(runName))"))

            // TODO: these tests would be much nicer if we had a controllable clock
            // the racy part is: if we wait for exactly the amount of time of the backoff,
            // we may be waiting "slightly too long" and get the unexpected message;
            // we currently work around this by waiting slightly less.

            pinfo("expect no restart for \(expectedBackoff)")
            let expectedSlightlyShortedToAvoidRaces = expectedBackoff - .milliseconds(50)
            try p.expectNoMessage(for: expectedSlightlyShortedToAvoidRaces)

            // it should finally restart though
            guard case .setupRunning(let faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }
            pinfo("restarted!")

            // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
            faultyWorkerRestarted.shouldEqual(faultyWorker)
        }

        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
    }

    func sharedTestLogic_restartSupervised_shouldRestartWithExponentialBackoff(
        runName: String,
        makeEvilMessage: @escaping (String) -> FaultyMessage
    ) throws {
        let initialInterval: DistributedActors.TimeAmount = .milliseconds(100)
        let multiplier = 2.0
        let backoff = Backoff.exponential(
            initialInterval: initialInterval,
            multiplier: multiplier,
            randomFactor: 0.0
        )

        let p = self.testKit.makeTestProbe(expecting: WorkerMessages.self)
        let pp = self.testKit.makeTestProbe(expecting: Never.self)

        let parentBehavior: _Behavior<Never> = .setup { context in
            let _: _ActorRef<FaultyMessage> = try context._spawn(
                "\(runName)-exponentialBackingOff",
                props: _Props().supervision(strategy: .restart(atMost: 10, within: nil, backoff: backoff)),
                self.faulty(probe: p.ref)
            )

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: _ActorRef<Never> = try system._spawn("\(runName)-parent-2", behavior)
        pp.watch(parent)

        guard case .setupRunning(let faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        func boomExpectBackoffRestart(expectedBackoff: DistributedActors.TimeAmount) throws {
            // confirm it is alive and working
            faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
            try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

            pinfo("make it crash")
            // make it crash
            faultyWorker.tell(makeEvilMessage("Boom: (\(runName))"))

            // TODO: these tests would be much nicer if we had a controllable clock
            // the racy part is: if we wait for exactly the amount of time of the backoff,
            // we may be waiting "slightly too long" and get the unexpected message;
            // we currently work around this by waiting slightly less.

            pinfo("expect no restart for \(expectedBackoff)")
            let expectedSlightlyShortedToAvoidRaces = expectedBackoff - .milliseconds(50)
            try p.expectNoMessage(for: expectedSlightlyShortedToAvoidRaces)

            // it should finally restart though
            guard case .setupRunning(let faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }
            pinfo("restarted!")

            // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
            faultyWorkerRestarted.shouldEqual(faultyWorker)
        }

        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(100))
        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(200))
        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(400))
    }

    func sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = self.testKit.makeTestProbe(expecting: WorkerMessages.self)
        let pp = self.testKit.makeTestProbe(expecting: Never.self)

        let failurePeriod: DistributedActors.TimeAmount = .seconds(1) // .milliseconds(300)

        let parentBehavior: _Behavior<Never> = .setup { context in
            let _: _ActorRef<FaultyMessage> = try context._spawn(
                "\(runName)-erroring-within-2",
                props: .supervision(strategy: .restart(atMost: 2, within: failurePeriod)),
                self.faulty(probe: p.ref)
            )
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: _ActorRef<Never> = try system._spawn("\(runName)-parent-2", behavior)
        pp.watch(parent)

        guard case .setupRunning(let faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        pinfo("1st boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("\(Date()) :: Giving enough breathing time to replenish the restart period (\(failurePeriod))")
        _Thread.sleep(failurePeriod)
        pinfo("\(Date()) :: Done sleeping...")

        pinfo("2nd boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 1st failure in period (2nd total) (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("3rd boom...")
        // cause another failure right away -- meaning in this period we are up to 2/2 failures
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 2nd failure in period (3rd total) (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate

        pinfo("4th boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 3rd failure in period (4th total) (\(runName))"))
        try p.expectTerminated(faultyWorker)
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("Now it boomed but did not crash again!")
    }

    func sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStart(failureMode: FailureMode) throws {
        let probe = self.testKit.makeTestProbe(expecting: String.self)

        let strategy: _SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        var shouldFail = true
        let behavior: _Behavior<String> = .setup { _ in
            if shouldFail {
                shouldFail = false // we only fail the first time
                probe.tell("failing")
                try failureMode.fail()
            }

            probe.tell("starting")

            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref: _ActorRef<String> = try system._spawn("fail-in-start-1", props: .supervision(strategy: strategy), behavior)

        try probe.expectMessage("failing")
        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
    }

    func sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStartAfterFailure(failureMode: FailureMode) throws {
        let probe = self.testKit.makeTestProbe(expecting: String.self)

        let strategy: _SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        // initial setup should not fail
        var shouldFail = false
        let behavior: _Behavior<String> = .setup { _ in
            if shouldFail {
                shouldFail = false
                probe.tell("setup:failing")
                try failureMode.fail()
            }

            shouldFail = true // next setup should fail

            probe.tell("starting")

            return .receiveMessage { message in
                switch message {
                case "boom": throw FaultyError.boom(message: "boom")
                default:
                    probe.tell("started:\(message)")
                    return .same
                }
            }
        }

        let ref: _ActorRef<String> = try system._spawn("fail-in-start-2", props: .supervision(strategy: strategy), behavior)

        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
        ref.tell("boom")
        try probe.expectMessage("setup:failing")
        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
    }

    func sharedTestLogic_restart_shouldFailAfterMaxFailuresInSetup(failureMode: FailureMode) throws {
        let probe = self.testKit.makeTestProbe(expecting: String.self)

        let strategy: _SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        let behavior: _Behavior<String> = .setup { _ in
            probe.tell("starting")
            try failureMode.fail()
            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref: _ActorRef<String> = try system._spawn("fail-in-start-3", props: .supervision(strategy: strategy), behavior)
        probe.watch(ref)
        for _ in 1 ... 5 {
            try probe.expectMessage("starting")
        }
        try probe.expectTerminated(ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Stopping supervision

    func test_stopSupervised_throws_shouldStop() throws {
        try self.sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(
            runName: "throws",
            makeEvilMessage: { msg in
                FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
            }
        )
    }

    func test_stopSupervised_throwsInAwaitResult_shouldStop() throws {
        try self.sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(
            runName: "throws",
            makeEvilMessage: { _ in
                FaultyMessage.pleaseFailAwaiting(message: "Boom!")
            }
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Restarting supervision

    func test_restartSupervised_throws_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(
            runName: "throws",
            makeEvilMessage: { msg in
                FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
            }
        )
    }

    func test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod() throws {
        try self.sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(
            runName: "throws",
            makeEvilMessage: { msg in
                FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
            }
        )
    }

    func test_restartSupervised_throwsInAwaitResult_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(
            runName: "throws",
            makeEvilMessage: { _ in
                FaultyMessage.pleaseFailAwaiting(message: "Boom!")
            }
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Escalating supervision

    func test_escalateSupervised_throws_shouldKeepEscalatingThrough_watchingParents() throws {
        let pt = self.testKit.makeTestProbe("pt", expecting: _ActorRef<String>.self)
        let pm = self.testKit.makeTestProbe("pm", expecting: _ActorRef<String>.self)
        let pab = self.testKit.makeTestProbe("pab", expecting: _ActorRef<String>.self)
        let pb = self.testKit.makeTestProbe("pb", expecting: _ActorRef<String>.self)
        let pp = self.testKit.makeTestProbe("pp", expecting: String.self)

        _ = try self.system._spawn(
            "top",
            of: String.self,
            .setup { c in
                pt.tell(c.myself)

                _ = try c._spawn(
                    "middle",
                    of: String.self,
                    props: .supervision(strategy: .escalate),
                    .setup { cc in
                        pm.tell(cc.myself)

                        // you can also just watch, this way the failure will be both in case of stop or crash; failure will be a Death Pact rather than indicating an escalation
                        _ = try cc._spawnWatch(
                            "almostBottom",
                            of: String.self,
                            .setup { ccc in
                                pab.tell(ccc.myself)

                                _ = try ccc._spawnWatch(
                                    "bottom",
                                    of: String.self,
                                    props: .supervision(strategy: .escalate),
                                    .setup { cccc in
                                        pb.tell(cccc.myself)
                                        return .receiveMessage { message in
                                            throw Boom(message)
                                        }
                                    }
                                )

                                return .ignore
                            }
                        )

                        return .ignore
                    }
                )

                return _Behavior<String>.receiveSpecificSignal(_Signals._ChildTerminated.self) { context, terminated in
                    pp.tell("Prevented escalation to top level in \(context.myself.path), terminated: \(terminated)")

                    return .same // stop the failure from reaching the guardian and terminating the system
                }
            }
        )

        let top = try pt.expectMessage()
        pt.watch(top)
        let middle = try pm.expectMessage()
        pm.watch(middle)
        let almostBottom = try pab.expectMessage()
        pab.watch(almostBottom)
        let bottom = try pb.expectMessage()
        pb.watch(bottom)

        bottom.tell("Boom!")

        let msg = try pp.expectMessage()
        msg.shouldContain("Prevented escalation to top level in /user/top")

        // Death Parade:
        try pb.expectTerminated(bottom) // Boom!
        try pab.expectTerminated(almostBottom) // Boom!
        try pm.expectTerminated(middle) // Boom!

        // top should not terminate since it handled the thing
        try pt.expectNoTerminationSignal(for: .milliseconds(200))
    }

    func test_escalateSupervised_throws_shouldKeepEscalatingThrough_nonWatchingParents() throws {
        let pt = self.testKit.makeTestProbe("pt", expecting: _ActorRef<String>.self)
        let pm = self.testKit.makeTestProbe("pm", expecting: _ActorRef<String>.self)
        let pab = self.testKit.makeTestProbe("pab", expecting: _ActorRef<String>.self)
        let pb = self.testKit.makeTestProbe("pb", expecting: _ActorRef<String>.self)
        let pp = self.testKit.makeTestProbe("pp", expecting: String.self)

        _ = try self.system._spawn(
            "top",
            of: String.self,
            .setup { c in
                pt.tell(c.myself)

                _ = try c._spawn(
                    "middle",
                    of: String.self,
                    props: .supervision(strategy: .escalate),
                    .setup { cc in
                        pm.tell(cc.myself)

                        _ = try cc._spawn(
                            "almostBottom",
                            of: String.self,
                            props: .supervision(strategy: .escalate),
                            .setup { ccc in
                                pab.tell(ccc.myself)

                                _ = try ccc._spawn(
                                    "bottom",
                                    of: String.self,
                                    props: .supervision(strategy: .escalate),
                                    .setup { cccc in
                                        pb.tell(cccc.myself)
                                        return .receiveMessage { message in
                                            throw Boom(message)
                                        }
                                    }
                                )

                                return .ignore
                            }
                        )

                        return .ignore
                    }
                )

                return _Behavior<String>.receiveSpecificSignal(_Signals._ChildTerminated.self) { context, terminated in
                    pp.tell("Prevented escalation to top level in \(context.myself.path), terminated: \(terminated)")

                    return .same // stop the failure from reaching the guardian and terminating the system
                }
            }
        )

        let top = try pt.expectMessage()
        pt.watch(top)
        let middle = try pm.expectMessage()
        pm.watch(middle)
        let almostBottom = try pab.expectMessage()
        pab.watch(almostBottom)
        let bottom = try pb.expectMessage()
        pb.watch(bottom)

        bottom.tell("Boom!")

        let msg = try pp.expectMessage()
        msg.shouldContain("Prevented escalation to top level in /user/top")

        // Death Parade:
        try pb.expectTerminated(bottom) // Boom!
        try pab.expectTerminated(almostBottom) // Boom!
        try pm.expectTerminated(middle) // Boom!

        // top should not terminate since it handled the thing
        try pt.expectNoTerminationSignal(for: .milliseconds(200))
    }

    func test_escalateSupervised_throws_shouldKeepEscalatingUntilNonEscalatingParent() throws {
        let pt = self.testKit.makeTestProbe("pt", expecting: _ActorRef<String>.self)
        let pm = self.testKit.makeTestProbe("pm", expecting: _ActorRef<String>.self)
        let pab = self.testKit.makeTestProbe("pab", expecting: _ActorRef<String>.self)
        let pb = self.testKit.makeTestProbe("pb", expecting: _ActorRef<String>.self)

        _ = try self.system._spawn(
            "top",
            of: String.self,
            .setup { c in
                pt.tell(c.myself)

                _ = try c._spawn(
                    "middle",
                    of: String.self,
                    .setup { cc in
                        pm.tell(cc.myself)

                        // does not watch or escalate child failures, this means that this is our "failure isolator"; failures will be stopped at this actor (!)
                        _ = try cc._spawn(
                            "almostBottom",
                            of: String.self,
                            .setup { ccc in
                                pab.tell(ccc.myself)

                                _ = try ccc._spawn(
                                    "bottom",
                                    of: String.self,
                                    props: .supervision(strategy: .escalate),
                                    .setup { cccc in
                                        pb.tell(cccc.myself)
                                        return .receiveMessage { message in
                                            throw Boom(message)
                                        }
                                    }
                                )

                                return .ignore
                            }
                        )

                        return .ignore
                    }
                )

                return .ignore
            }
        )

        let top = try pt.expectMessage()
        pt.watch(top)
        let middle = try pm.expectMessage()
        pm.watch(middle)
        let almostBottom = try pab.expectMessage()
        pab.watch(almostBottom)
        let bottom = try pb.expectMessage()
        pb.watch(bottom)

        bottom.tell("Boom!")

        // Death Parade:
        try pb.expectTerminated(bottom) // Boom!
        try pab.expectTerminated(almostBottom) // Boom!
        // Boom!

        // the almost bottom has isolated the fault; it does not leak more upwards the tree
        try pm.expectNoTerminationSignal(for: .milliseconds(100))
        try pt.expectNoTerminationSignal(for: .milliseconds(100))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Restarting supervision with Backoff

    func test_restart_throws_shouldHandleFailureWhenInterpretingStart() throws {
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStart(failureMode: .throwing)
    }

    func test_restartSupervised_throws_shouldRestartWithConstantBackoff() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestartWithConstantBackoff(
            runName: "throws",
            makeEvilMessage: { msg in
                FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
            }
        )
    }

    func test_restartSupervised_throws_shouldRestartWithExponentialBackoff() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestartWithExponentialBackoff(
            runName: "throws",
            makeEvilMessage: { msg in
                FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
            }
        )
    }

    func test_restart_throws_shouldHandleFailureWhenInterpretingStartAfterFailure() throws {
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStartAfterFailure(failureMode: .throwing)
    }

    func test_restart_throws_shouldFailAfterMaxFailuresInSetup() throws {
        try self.sharedTestLogic_restart_shouldFailAfterMaxFailuresInSetup(failureMode: .throwing)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Composite handler tests

    func test_compositeSupervisor_shouldHandleUsingTheRightHandler() throws {
        let probe = self.testKit.makeTestProbe(expecting: WorkerMessages.self)

        let faultyWorker = try system._spawn(
            "compositeFailures-1",
            props: _Props()
                .supervision(strategy: .restart(atMost: 1, within: nil), forErrorType: CatchMeError.self)
                .supervision(strategy: .restart(atMost: 1, within: nil), forErrorType: EasilyCatchableError.self),
            self.faulty(probe: probe.ref)
        )

        probe.watch(faultyWorker)

        faultyWorker.tell(.pleaseThrow(error: CatchMeError()))
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseThrow(error: EasilyCatchableError()))
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseThrow(error: CantTouchThisError()))
        try probe.expectTerminated(faultyWorker)
    }

    // TODO: we should nail down and spec harder exact semantics of the failure counting, I'd say we do.
    // I think that IFF we do subclassing checks then it makes sense to only increment the specific supervisor,
    // but since we do NOT do the subclassing let's keep to the "linear scan during which we +1 every encountered one"
    // and when we hit the right one we trigger its logic. In other words the counts are cumulative within the period --
    // regardless which failures they caused...? Then one could argue that we need to always +1 all of them, which also is fair...
    // All in all, TODO and cement the meaning in docs and tests.

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling faults inside receiveSignal

    func sharedTestLogic_failInSignalHandling_shouldRestart(failBy failureMode: FailureMode) throws {
        let parentProbe = self.testKit.makeTestProbe(expecting: String.self)
        let workerProbe = self.testKit.makeTestProbe(expecting: WorkerMessages.self)

        // parent spawns a new child for every message it receives, the workerProbe gets the reference so we can crash it then
        let parentBehavior = _Behavior<String>.receive { context, _ in
            let faultyBehavior = self.faulty(probe: workerProbe.ref)
            try context._spawn("\(failureMode)-child", faultyBehavior)

            return .same
        }.receiveSignal { _, signal in
            if let terminated = signal as? _Signals.Terminated {
                parentProbe.tell("terminated:\(terminated.id.name)")
                try failureMode.fail()
            }
            return .same
        }

        let parentRef: _ActorRef<String> = try system._spawn(
            "parent",
            props: .supervision(strategy: .restart(atMost: 2, within: nil)),
            parentBehavior
        )
        parentProbe.watch(parentRef)

        parentRef.tell("spawn")
        guard case .setupRunning(let workerRef1) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef1)
        workerRef1.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef1)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("2nd child crash round")
        parentRef.tell("spawn")
        guard case .setupRunning(let workerRef2) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef2)
        workerRef2.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef2)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("3rd child crash round, parent restarts exceeded")
        parentRef.tell("spawn")
        guard case .setupRunning(let workerRef3) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef3)
        workerRef3.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef3)
        try parentProbe.expectTerminated(parentRef)
    }

    func test_throwInSignalHandling_shouldRestart() throws {
        try self.sharedTestLogic_failInSignalHandling_shouldRestart(failBy: .throwing)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Tests for selective failure handlers

    /// Throws all Errors it receives, EXCEPT `PleaseReplyError` to which it replies to the probe
    private func throwerBehavior(probe: ActorTestProbe<PleaseReplyError>) -> _Behavior<NonTransportableAnyError> {
        .receiveMessage { errorEnvelope in
            switch errorEnvelope.failure {
            case let reply as PleaseReplyError:
                probe.tell(reply)
            case let failure:
                throw failure
            }
            return .same
        }
    }

    func test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType() throws {
        let p = self.testKit.makeTestProbe(expecting: PleaseReplyError.self)

        let supervisedThrower: _ActorRef<NonTransportableAnyError> = try system._spawn(
            "thrower-1",
            props: .supervision(strategy: .restart(atMost: 10, within: nil), forErrorType: EasilyCatchableError.self),
            self.throwerBehavior(probe: p)
        )

        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectMessage(PleaseReplyError())

        supervisedThrower.tell(.init(EasilyCatchableError())) // will cause restart
        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectMessage(PleaseReplyError())

        supervisedThrower.tell(.init(CatchMeError())) // will NOT be supervised

        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func test_supervisor_shouldOnlyHandle_anyThrows() throws {
        let p = self.testKit.makeTestProbe(expecting: PleaseReplyError.self)

        let supervisedThrower: _ActorRef<NonTransportableAnyError> = try system._spawn(
            "thrower-2",
            props: .supervision(strategy: .restart(atMost: 100, within: nil), forAll: .errors),
            self.throwerBehavior(probe: p)
        )

        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectMessage(PleaseReplyError())

        supervisedThrower.tell(.init(EasilyCatchableError())) // will cause restart
        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectMessage(PleaseReplyError())

        supervisedThrower.tell(.init(CatchMeError())) // will cause restart

        supervisedThrower.tell(.init(PleaseReplyError()))
        try p.expectMessage(PleaseReplyError())
    }

    func sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = _Behavior.receiveMessage { _ in
            try failureMode.fail()
            return .same
        }.receiveSignal { _, signal in
            if signal is _Signals._PreRestart {
                p.tell("preRestart")
            }
            return .same
        }

        let ref = try system._spawn(.anonymous, props: .supervision(strategy: .restart(atMost: 1, within: .seconds(5))), behavior)
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("preRestart")

        ref.tell("test")
        try p.expectTerminated(ref)
    }

    func test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting() throws {
        try self.sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy: .throwing)
    }

    func sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy failureMode: FailureMode, backoff: BackoffStrategy?) throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        var preRestartCounter = 0

        let failOnBoom: _Behavior<String> = _Behavior.receiveMessage { message in
            if message == "boom" {
                try failureMode.fail()
            }
            return .same
        }.receiveSignal { _, signal in

            if signal is _Signals._PreRestart {
                preRestartCounter += 1
                p.tell("preRestart-\(preRestartCounter)")
                try failureMode.fail()
                p.tell("NEVER")
            }
            return .same
        }

        let ref = try system._spawn("fail-onside-pre-restart", props: .supervision(strategy: .restart(atMost: 3, within: nil, backoff: backoff)), failOnBoom)
        p.watch(ref)

        ref.tell("boom")
        try p.expectMessage("preRestart-1")
        try p.expectMessage("preRestart-2") // keep trying...
        try p.expectMessage("preRestart-3") // last try...

        ref.tell("hello")
        try p.expectNoMessage(for: .milliseconds(100))

        try p.expectTerminated(ref)
    }

    func test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal() throws {
        try self.sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .throwing, backoff: nil)
    }

    func test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal_withBackoff() throws {
        try self.sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .throwing, backoff: Backoff.constant(.milliseconds(10)))
    }

    func test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .receiveMessage { msg in
            p.tell("crashing:\(msg)")
            return .stop { _ in
                throw FaultyError.boom(message: "test")
            }
        }

        let ref = try system._spawn(.anonymous, props: .supervision(strategy: .restart(atMost: 5, within: .seconds(5))), behavior)
        p.watch(ref)

        ref.tell("test")

        try p.expectMessage("crashing:test")
        try p.expectTerminated(ref)

        ref.tell("test2")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func sharedTestLogic_supervisor_shouldRestartWhenFailingInDispatchedClosure(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .setup { _ in
            p.tell("setup")
            return .receive { context, msg in
                let cb: AsynchronousCallback<String> = context.makeAsynchronousCallback { str in
                    p.tell("crashing:\(str)")
                    try failureMode.fail()
                }

                (context as! _ActorShell<String>)._dispatcher.execute {
                    cb.invoke(msg)
                }

                return .same
            }
        }

        let ref = try system._spawn(.anonymous, props: .supervision(strategy: .restart(atMost: 5, within: .seconds(5))), behavior)
        p.watch(ref)

        try p.expectMessage("setup")

        ref.tell("test")
        try p.expectMessage("crashing:test")
        try p.expectNoTerminationSignal(for: .milliseconds(50))

        try p.expectMessage("setup")
        ref.tell("test2")
        try p.expectMessage("crashing:test2")
    }

    func test_supervisor_throws_shouldRestartWhenFailingInDispatchedClosure() throws {
        try self.sharedTestLogic_supervisor_shouldRestartWhenFailingInDispatchedClosure(failBy: .throwing)
    }

    func sharedTestLogic_supervisor_awaitResult_shouldInvokeSupervisionWhenFailing(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = elg.next()
        let promise = el.makePromise(of: Int.self)
        let future = promise.futureResult

        let behavior: _Behavior<String> = .setup { context in
            p.tell("starting")
            return .receiveMessage { message in
                switch message {
                case "suspend":
                    return context.awaitResult(of: future, timeout: .milliseconds(100)) { _ in
                        try failureMode.fail()
                        return .same
                    }
                default:
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system._spawn(.anonymous, props: _Props.supervision(strategy: .restart(atMost: 1, within: .seconds(1))), behavior)

        try p.expectMessage("starting")
        ref.tell("suspend")
        promise.succeed(1)
        try p.expectMessage("starting")
    }

    func test_supervisor_awaitResult_shouldInvokeSupervisionOnThrow() throws {
        try self.sharedTestLogic_supervisor_awaitResult_shouldInvokeSupervisionWhenFailing(failBy: .throwing)
    }

    func test_supervisor_awaitResultThrowing_shouldInvokeSupervisionOnFailure() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = elg.next()
        let promise = el.makePromise(of: Int.self)
        let future = promise.futureResult

        let behavior: _Behavior<String> = .setup { context in
            p.tell("starting")
            return .receiveMessage { message in
                switch message {
                case "suspend":
                    return context.awaitResultThrowing(of: future, timeout: .milliseconds(100)) { _ in
                        .same
                    }
                default:
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system._spawn(.anonymous, props: _Props.supervision(strategy: .restart(atMost: 1, within: .seconds(1))), behavior)

        try p.expectMessage("starting")
        ref.tell("suspend")
        promise.fail(FaultyError.boom(message: "boom"))
        try p.expectMessage("starting")
    }

    private struct PleaseReplyError: Error, Codable, Equatable {}
    private struct EasilyCatchableError: Error, Equatable {}
    private struct CantTouchThisError: Error, Equatable {}
    private struct CatchMeError: Error, Equatable {}
}
