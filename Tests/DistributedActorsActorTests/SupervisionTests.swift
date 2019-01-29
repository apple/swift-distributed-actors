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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

class SupervisionTests: XCTestCase {

    let system = ActorSystem("SupervisionTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }
    enum FaultyError: Error {
        case boom(message: String)
    }
    enum FaultyMessages  {
        case pleaseThrow(error: Error)
        case pleaseFatalError(message: String)
        case pleaseDivideByZero
        case echo(message: String, replyTo: ActorRef<WorkerMessages>)
    }

    enum SimpleProbeMessages: Equatable {
        case spawned(child: ActorRef<FaultyMessages>)
        case echoing(message: String)
    }

    enum WorkerMessages: Equatable {
        case setupRunning(ref: ActorRef<FaultyMessages>)
        case echo(message: String)
    }

    enum FailureMode {
        case throwing
        case faulting
    }

    func faulty(probe: ActorRef<WorkerMessages>?) -> Behavior<FaultyMessages> {
        return .setup { context in
            probe?.tell(.setupRunning(ref: context.myself))

            return .receiveMessage {
                switch $0 {
                case .pleaseThrow(let error):
                    throw error
                case .pleaseFatalError(let msg):
                    fatalError(msg)
                case .pleaseDivideByZero:
                    let zero = Int("0")! // to trick swiftc into allowing us to write "/ 0", which it otherwise catches at compile time
                    _ = 100 / zero
                    return .same
                case let .echo(msg, sender):
                    sender.tell(.echo(message: "echo:\(msg)"))
                    return .same
                }
            }
        }
    }

    // TODO: test a double fault (throwing inside of a supervisor

    // TODO: implement and test exponential backoff supervision

    func compileOnlyDSLReadabilityTest() {
        _ = { () -> Void in
            let behavior: Behavior<String> = undefined()
            _ = try self.system.spawn(behavior, name: "example")
            _ = try self.system.spawn(behavior, name: "example", props: Props())
            _ = try self.system.spawn(behavior, name: "example", props: .withDispatcher(.PinnedThread))
            _ = try self.system.spawn(behavior, name: "example", props: Props().withDispatcher(.PinnedThread).addSupervision(strategy: .stop))
            // nope: _ = try self.system.spawn(behavior, name: "example", props: .withDispatcher(.PinnedThread).addSupervision(strategy: .stop))
            // /Users/ktoso/code/sact/Tests/Swift Distributed ActorsActorTests/SupervisionTests.swift:120:15: error: expression type '()' is ambiguous without more context
            _ = try self.system.spawn(behavior, name: "example", props: .addSupervision(strategy: .restart(atMost: 5, within: .seconds(1))))
            _ = try self.system.spawn(behavior, name: "example", props: .addSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite)))

            // chaining
            _ = try self.system.spawn(behavior, name: "example",
                props: Props()
                    .addSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite))
                    .withDispatcher(.PinnedThread)
                    .withMailbox(.default(capacity: 122, onOverflow: .crash))
            )

            _ = try self.system.spawn(behavior, name: "example",
                props: Props()
                    .addSupervision(strategy: .restart(atMost: 5, within: .seconds(1)), for: EasilyCatchable.self)
                    .addSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite))
                    .addSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite)) // we allow 10 crashes _in total_ for this actor
            )
        }
    }

    // MARK: Shared test implementation, which is to run with either error/fault causing messages

    func sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: String, makeEvilMessage: (String) -> FaultyMessages) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)


        let parentBehavior: Behavior<Never> = .setup { context in
            let strategy: SupervisionStrategy = .stop
            let behavior = self.faulty(probe: p.ref)
            let _: ActorRef<FaultyMessages> = try context.spawn(behavior, name: "\(runName)-erroring-1", 
                props: .addSupervision(strategy: strategy))
            return .same
        }
        let interceptedParent = pp.interceptAllMessages(sentTo: parentBehavior) // TODO intercept not needed

        let parent: ActorRef<Never> = try system.spawn(interceptedParent, name: "\(runName)-parent")

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }

        p.watch(faultyWorker)
        faultyWorker.tell(makeEvilMessage("Boom"))

        // it should have stopped on the failure
        try p.expectTerminated(faultyWorker)

        // meaning that the .stop did not accidentally also cause the parent to die
        // after all, it dod NOT watch the faulty actor, so death pact also does not come into play
        pp.watch(parent)
        try pp.expectNoTerminationSignal(for: .milliseconds(100))

    }

    func sharedTestLogic_restartSupervised_shouldRestart(runName: String, makeEvilMessage: (String) -> FaultyMessages) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)


        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(self.faulty(probe: p.ref), name: "\(runName)-erroring-2", 
                props: Props().addSupervision(strategy: .restart(atMost: 2, within: .seconds(1))))

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate

        pinfo("Now expecting it to run setup again...")
        guard case let .setupRunning(faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }

        // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
        faultyWorkerRestarted.shouldEqual(faultyWorker)

        pinfo("Not expecting a reply from it")
        faultyWorker.tell(.echo(message: "two", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:two"))


        faultyWorker.tell(makeEvilMessage("Boom: 2nd (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300))

        pinfo("Now it boomed but did not crash again!")
    }

    func sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: String, makeEvilMessage: (String) -> FaultyMessages) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let failurePeriod: TimeAmount = .seconds(1) // .milliseconds(300)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(self.faulty(probe: p.ref), name: "\(runName)-erroring-within-2", 
                props: .addSupervision(strategy: .restart(atMost: 2, within: failurePeriod)))
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        pinfo("1st boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("\(Date()) :: Giving enough breathing time to replenish the restart period (\(failurePeriod))")
        Thread.sleep(failurePeriod)
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

    // MARK: Stopping supervision

    func test_stopSupervised_throws_shouldStop() throws {
        try self.sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: "throws", makeEvilMessage: { msg in
            FaultyMessages.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_stopSupervised_fatalError_shouldStop() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseFatalError(message: msg)
        })
        #endif
    }

    // MARK: Restarting supervision

    func test_restartSupervised_fatalError_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseFatalError(message: msg)
        })
        #endif
    }
    func test_restartSupervised_throws_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "throws", makeEvilMessage: { msg in
            FaultyMessages.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod() throws {
        try self.sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: "throws", makeEvilMessage: { msg in 
            FaultyMessages.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }
    func test_restartAtMostWithin_fatalError_shouldRestartNoMoreThanAllowedWithinPeriod() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseFatalError(message: msg)
        })
        #endif
    }

    // MARK: Handling faults, divide by zero
    // This should effectively be exactly the same as other faults, but we want to make sure, just in case Swift changes this (so we'd notice early)

    func test_stopSupervised_divideByZero_shouldStop() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseDivideByZero
        })
        #endif
    }

    func test_restartSupervised_divideByZero_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseDivideByZero
        })
        #endif
    }

    // MARK: Flattening supervisors so we do not end up with infinite stacks of same supervisor
    // TODO: implement for new scheme

    // MARK: Handling faults inside receiveSignal

    func sharedTestLogic_failInSignalHandling_shouldRestart(failBy failureMode: FailureMode) throws {
        let parentProbe = testKit.spawnTestProbe(expecting: String.self)
        let workerProbe = testKit.spawnTestProbe(expecting: WorkerMessages.self)

        // parent spawns a new child for every message it receives, the workerProbe gets the reference so we can crash it then
        let parentBehavior = Behavior<String>.receive { context, msg in
                let faultyBehavior = self.faulty(probe: workerProbe.ref)
                let _ = try context.spawn(faultyBehavior, name: "\(failureMode)-child")

                return .same
            }.receiveSignal { context, signal in
                if let terminated = signal as? Signals.Terminated {
                    parentProbe.tell("terminated:\(terminated.path.name)")
                    switch failureMode {
                    case .faulting: fatalError("SIGNAL_BOOM")
                    case .throwing: throw FaultyError.boom(message: "SIGNAL_BOOM")
                    }
                }
                return .same
            }

        let parentRef: ActorRef<String> = try system.spawn(parentBehavior, name: "parent",
            props: .addSupervision(strategy: .restart(atMost: 2, within: nil)))
        parentProbe.watch(parentRef)

        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef1) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef1)
        workerRef1.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef1)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("2nd child crash round")
        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef2) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef2)
        workerRef2.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef2)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("3rd child crash round, parent restarts exceeded")
        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef3) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef3)
        workerRef3.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef3)
        try parentProbe.expectTerminated(parentRef)
    }

    func test_throwInSignalHandling_shouldRestart() throws {
        try self.sharedTestLogic_failInSignalHandling_shouldRestart(failBy: .throwing)
    }
    func test_faultInSignalHandling_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_failInSignalHandling_shouldRestart(failBy: .faulting)
        #endif
    }

    // MARK: Hard crash tests, hidden under flags (since they really crash the application, and SHOULD do so)

    func test_supervise_notSuperviseStackOverflow() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function); The test exists to confirm that this type of fault remains NOT supervised. See it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \(#function); The test exists to confirm that this type of fault remains NOT supervised. See it crash run with `-D SACT_TESTS_CRASH`"

        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let stackOverflowFaulty: Behavior<SupervisionTests.FaultyMessages> = .setup { context in
            p.tell(.setupRunning(ref: context.myself))
            return .receiveMessage { message in
                return self.daDoRunRunRunDaDoRunRun()
            }
        }

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(stackOverflowFaulty, name: "bad-decision-erroring-2",
                props: .addSupervision(strategy: .restart(atMost: 3, within: .seconds(5))))
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "bad-decision-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom: 1st (bad-decision)")))
        try p.expectTerminated(faultyWorker) // faulty worker DID terminate, since the decision was bogus (".same")
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate
    }
    func daDoRunRunRun() -> Behavior<SupervisionTests.FaultyMessages> {
        return daDoRunRunRunDaDoRunRun() // mutually recursive to not trigger warnings; cause stack overflow
    }
    func daDoRunRunRunDaDoRunRun() -> Behavior<SupervisionTests.FaultyMessages> {
        return daDoRunRunRun() // mutually recursive to not trigger warnings; cause stack overflow
    }

    // MARK: Tests for selective failure handlers

    /// Throws all Errors it receives, EXCEPT `PleaseReply` to which it replies to the probe
    private func throwerBehavior(probe: ActorTestProbe<PleaseReply>) -> Behavior<Error> {
        return .receiveMessage { error in
            switch error {
            case let reply as PleaseReply:
                probe.tell(reply)
            case is PleaseFatalError:
                fatalError("Boom! Fatal error on demand.")
            default:
                throw error
            }
            return .same
        }
    }

    func test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType() throws {
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "thrower-1",
            props: .addSupervision(strategy: .restart(atMost: 100, within: nil), for: EasilyCatchable.self))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(EasilyCatchable()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will NOT be supervised

        supervisedThrower.tell(PleaseReply())
        try p.expectNoMessage(for: .milliseconds(50))

    }
    func test_supervisor_shouldOnlyHandle_anyThrows() throws {
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "thrower-2",
            props: .addSupervision(strategy: .restart(atMost: 100, within: nil), for: Supervise.AllErrors.self))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(EasilyCatchable()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

    }
    func test_supervisor_shouldOnlyHandle_anyFault() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "mr-fawlty-1",
            props: .addSupervision(strategy: .restart(atMost: 100, within: nil), for: Supervise.AllFaults.self))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(PleaseFatalError()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will NOT cause restart, we only handle faults here (as unusual of a decision this is, yeah)

        supervisedThrower.tell(PleaseReply())
        try p.expectNoMessage(for: .milliseconds(50))
        #endif
    }
    func test_supervisor_shouldOnlyHandle_anyFailure() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "any-failure-1",
            props: .addSupervision(strategy: .restart(atMost: 100, within: nil), for: Supervise.AllFailures.self))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(PleaseFatalError()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())
        #endif
    }

    func sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = Behavior.receiveMessage { _ in
            switch failureMode {
            case .throwing: throw FaultyError.boom(message: "test")
            case .faulting: fatalError("BOOM")
            }
        }.receiveSignal { _, signal in
            if signal is Signals.PreRestart {
                p.tell("preRestart")
            }
            return .same
        }

        let ref = try system.spawnAnonymous(behavior, props: .addSupervision(strategy: .restart(atMost: 1, within: .seconds(5))))
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("preRestart")

        ref.tell("test")
        try p.expectTerminated(ref)
    }

    func test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting() throws {
        try sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy: .throwing)
    }

    func test_supervisor_fatalError_shouldCausePreRestartSignalBeforeRestarting() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy: .faulting)
        #else
        pinfo("Skipping test, SACT_DISABLE_FAULT_TESTING was set")
        #endif
    }

    func test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior = Behavior<String>.receiveMessage { msg in
            p.tell("crashing:\(msg)")
            return .stopped { _ in
                throw FaultyError.boom(message: "test")
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: .addSupervision(strategy: .restart(atMost: 5, within: .seconds(5))))
        p.watch(ref)

        ref.tell("test")

        try p.expectMessage("crashing:test")
        try p.expectTerminated(ref)

        ref.tell("test2")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    private struct PleaseReply: Error, Equatable, CustomStringConvertible {
        var description: String { return "PleaseReply" }
    }
    private struct EasilyCatchable: Error, Equatable, CustomStringConvertible {
        var description: String { return "EasilyCatchable" }
    }
    private struct PleaseFatalError: Error, Equatable, CustomStringConvertible {
        var description: String { return "PleaseFatalError" }
    }
    private struct CatchMe: Error, Equatable, CustomStringConvertible {
        var description: String { return "CatchMe" }
    }

}

