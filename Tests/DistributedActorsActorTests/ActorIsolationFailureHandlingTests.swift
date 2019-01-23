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

class ActorIsolationFailureHandlingTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }

    private enum SimpleTestError: Error {
        case simpleError(reason: String)
    }

    enum SimpleProbeMessages: Equatable {
        case spawned(child: ActorRef<FaultyWorkerMessages>)
        case echoing(message: String)
    }
    enum FaultyWorkerMessages {
        case work(n: Int, divideBy: Int)
        case throwError(error: Error)
    }
    enum WorkerError: Error {
        case error(code: Int)
    }

    func faultyWorkerBehavior(probe pw: ActorRef<Int>) -> Behavior<FaultyWorkerMessages> {
        return .receive { context, message in
            context.log.info("Working on: \(message)")
            switch message {
            case let .work(n, divideBy):
                pw.tell(n / divideBy)
                return .same
            case let .throwError(error):
                context.log.warning("Throwing as instructed, error: \(error)")
                throw error
            }
        }
    }

    let spawnFaultyWorkerCommand = "spawnFaultyWorker"
    func healthyMasterBehavior(pm: ActorRef<SimpleProbeMessages>, pw: ActorRef<Int>) -> Behavior<String> {
        return .receive { context, message in
            switch message {
            case self.spawnFaultyWorkerCommand:
                let worker = try context.spawn(self.faultyWorkerBehavior(probe: pw), name: "faultyWorker")
                pm.tell(.spawned(child: worker))
            default:
                pm.tell(.echoing(message: message))
            }
            return .same
        }
    }

    func test_worker_crashOnlyWorkerOnPlainErrorThrow() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = testKit.spawnTestProbe(name: "testProbe-master-1")
        let pw: ActorTestProbe<Int> = testKit.spawnTestProbe(name: "testProbeForWorker-1")

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster")

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell("spawnFaultyWorker")
        guard case let .spawned(worker) = try pm.expectMessage() else { throw pm.failure() }

        // watch the worker and see that it works correctly:
        pw.watch(worker)
        worker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        worker.tell(.throwError(error: WorkerError.error(code: 418))) // BOOM!

        // the worker, should have terminated due to the error:
        try pw.expectTerminated(worker)

        // even though the worker crashed, the parent is still alive (!)
        let stillAlive = "still alive"
        healthyMaster.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "still alive"))
    }

    func test_worker_crashOnlyWorkerOnDivisionByZero() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = testKit.spawnTestProbe(name: "testProbe-master-2")
        let pw: ActorTestProbe<Int> = testKit.spawnTestProbe(name: "testProbeForWorker-2")

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster")

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell(spawnFaultyWorkerCommand)
        guard case let .spawned(worker) = try pm.expectMessage() else { throw pm.failure() }

        // watch the worker and see that it works correctly:
        pw.watch(worker)
        worker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        worker.tell(.work(n: 100, divideBy: 0)) // BOOM!
        try pw.expectNoMessage(for: .milliseconds(200)) // code after the divide-by-zero should not be allowed to execute

        // the worker, should have terminated due to the error:
        let workerTerminated = try pw.expectTerminated(worker)
        pinfo("Good: \(workerTerminated)")

        // even though the worker crashed, the parent is still alive (!)
        let stillAlive = "still alive"
        healthyMaster.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "still alive"))
        pinfo("Good: Parent \(healthyMaster) still active.")

        // we are also now able to start a replacement actor for the terminated child:
        healthyMaster.tell(spawnFaultyWorkerCommand)
        pinfo("Good: Parent \(healthyMaster) was able to spawn new worker under the same name (unregistering of dead child worked).")
        guard case let .spawned(workerReplacement) = try pm.expectMessage() else { throw pm.failure() }

        let workerPath: UniqueActorPath = worker.path
        let replacementPath: UniqueActorPath = workerReplacement.path
        replacementPath.path.shouldEqual(workerPath.path) // same path
        replacementPath.uid.shouldNotEqual(workerPath.uid) // NOT same uid
        workerReplacement.shouldNotEqual(worker) // NOT same identity

        workerReplacement.tell(.work(n: 1000, divideBy: 100))
        try pw.expectMessage(10)
        // FIXME this is not complete
    }

    func test_worker_shouldBeAbleToHaveReplacementStartedByParentOnceItSeesPreviousChildTerminated() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = testKit.spawnTestProbe(name: "testProbe-master-3")
        let pw: ActorTestProbe<Int> = testKit.spawnTestProbe(name: "testProbe-faultyWorker")

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster")

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell(spawnFaultyWorkerCommand)
        guard case let .spawned(worker) = try pm.expectMessage() else { throw pm.failure() }
        pw.watch(worker)

        // watch the worker and see that it works correctly:
        pw.watch(worker)
        worker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        worker.tell(.work(n: 100, divideBy: 0)) // BOOM!
        try pw.expectNoMessage(for: .milliseconds(500)) // code after the divide-by-zero should not be allowed to execute

        // the worker, should have terminated due to the error:
        let workerTerminated = try pw.expectTerminated(worker)
        pinfo("Good: \(workerTerminated)")

        // we are also now able to start a replacement actor for the terminated child:
        healthyMaster.tell(spawnFaultyWorkerCommand)
        guard case let .spawned(workerReplacement) = try pm.expectMessage() else { throw pm.failure() }
        pw.watch(workerReplacement)

        let workerPath: UniqueActorPath = worker.path
        let replacementPath: UniqueActorPath = workerReplacement.path
        replacementPath.path.shouldEqual(workerPath.path) // same path
        replacementPath.uid.shouldNotEqual(workerPath.uid) // NOT same uid
        workerReplacement.shouldNotEqual(worker) // NOT same identity

        pinfo("Good: Parent \(healthyMaster) was able to spawn new worker under the same name (unregistering of dead child worked).")

        workerReplacement.tell(.work(n: 1000, divideBy: 100))
        try pw.expectMessage(10)
    }

    func test_crashOutsideOfActor_shouldStillFailLikeUsual() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function), can't that a fatalError() kills the process, it would kill the test suite; To see it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \(#function), can't that a fatalError() kills the process, it would kill the test suite; To see it crash run with `-D SACT_TESTS_CRASH`"

        fatalError("Boom like usual!")
        // this MUST NOT trigger Swift Distributed Actors failure handling, we are not inside of an actor!
    }

}

