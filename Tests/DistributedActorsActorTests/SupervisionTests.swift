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


    func faulty(probe: ActorRef<WorkerMessages>?) -> Behavior<FaultyMessages> {
        return .setup { context in
            probe?.tell(.setupRunning(ref: context.myself))

            return .receiveMessage {
                switch $0 {
                case .pleaseThrow(let error):
                    throw error
                case .pleaseFatalError(let msg):
                    fatalError(msg)
                case let .echo(msg, sender):
                    sender.tell(.echo(message: "echo:\(msg)"))
                    return .same
                }
            }
        }
    }

    // TODO: test a double fault (throwing inside of a supervisor

    // TODO: test div by zero or similar things, all "should just work", but we want to know in case swift changes something

    // TODO: test that does some really bad things and segfaults; we DO NOT want to handle this and should hard crash

    // TODO: exceed max restarts counter of a restart supervisor

    // TODO: implement and test exponential backoff supervision

    // TODO: test failures inside signal handling

    func test_compile() throws {
        let faultyWorker: Behavior<String> = .ignore

        // supervise

        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .stop)
        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .restart(atMost: 3))

        // supervised

        let _: Behavior<String> = faultyWorker.supervisedWith(strategy: .stop)
    }

    // MARK: Shared test implementation, which is to run with either error/fault causing messages

    func sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: String, makeEvilMessage: (String) -> FaultyMessages) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let strategy: SupervisionStrategy = .stop
        let supervisedBehavior: Behavior<FaultyMessages> = .supervise(self.faulty(probe: p.ref), withStrategy: strategy)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(supervisedBehavior, name: "\(runName)-erroring-1")
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior) // TODO intercept not needed

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent")

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.failure() }

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

        let strategy: SupervisionStrategy = .restart(atMost: 1)
        let supervisedBehavior: Behavior<FaultyMessages> = .supervise(self.faulty(probe: p.ref), withStrategy: strategy)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(supervisedBehavior, name: "\(runName)-erroring-2")
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.failure() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate

        pinfo("Now expecting it to run setup again...")
        guard case let .setupRunning(faultyWorkerRestarted) = try p.expectMessage() else { throw p.failure() }

        // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
        faultyWorkerRestarted.shouldEqual(faultyWorker)

        pinfo("Not expecting a reply from it")
        faultyWorker.tell(.echo(message: "two", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:two"))


        faultyWorker.tell(makeEvilMessage("Boom: 2nd (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300))

        pinfo("Now it boomed but did not crash again!")
    }

    // MARK: Handling Swift Errors

    func test_stopSupervised_throws_shouldStop() throws {
        try self.sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: "throws", makeEvilMessage: { msg in
            FaultyMessages.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_restartSupervised_throws_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "throws", makeEvilMessage: { msg in
            FaultyMessages.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    // MARK: Handling faults

    func test_stopSupervised_fatalError_shouldStop() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseFatalError(message: msg)
        })
    }

    func test_restartSupervised_fatalError_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessages.pleaseFatalError(message: msg)
        })
    }

    // MARK: Flattening supervisors so we do not end up with infinite stacks of same supervisor

    func test_wrappingWithSupervisionStrategy_shouldNotInfinitelyKeepGrowingTheBehaviorDepth() throws {
        let behavior: Behavior<String> = .receiveMessage { message in
            return .stopped
        }

        let w1 = behavior.supervisedWith(strategy: .stop)
        let w2 = w1.supervisedWith(strategy: .stop)

        let context: ActorContext<String> = testKit.makeFailingContext()

        let depth1 = try w1.nestingDepth(context: context)
        pinfo("w1 is: \n\(try w1.prettyFormat(context: context))")

        let depth2 = try w2.nestingDepth(context: context)
        pinfo("w2 is: \n\(try w2.prettyFormat(context: context))")

        depth1.shouldEqual(depth2)
    }

    func test_wrappingWithSupervisionStrategy_shouldWrapProperlyIfDifferentStrategy() throws {
        let behavior: Behavior<String> = .receiveMessage { message in
            return .stopped
        }

        let w1 = behavior.supervisedWith(strategy: .restart(atMost: 3)) // e.g. "we can restart a few times"
        let w2 = w1.supervisedWith(strategy: .stop) // "but of those fail, and bubble up, we need to stop"

        let context: ActorContext<String> = testKit.makeFailingContext()

        let depth1 = try w1.nestingDepth(context: context)
        pinfo("w1 is: \n\(try w1.prettyFormat(context: context))")

        let depth2 = try w2.nestingDepth(context: context)
        pinfo("w2 is: \n\(try w2.prettyFormat(context: context))")

        depth2.shouldEqual(depth1 + 1) // since the wrapping SHOULD have happened
    }


}

