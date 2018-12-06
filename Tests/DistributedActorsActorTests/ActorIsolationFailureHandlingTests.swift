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

    let isolateFaultDomainProps = Props().withFaultDomain(.isolate)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
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
                context.log.warn("Throwing as instructed, error: \(error)")
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
        let pm: ActorTestProbe<SimpleProbeMessages> = testKit.spawnTestProbe(name: "testProbe-master")
        let pw: ActorTestProbe<Int> = testKit.spawnTestProbe(name: "testProbe-faultyWorker")

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster")

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell("spawnFaultyWorker")
        guard case let .spawned(childWorker) = try pm.expectMessage() else { fatalError("did not receive expected message") }

        // watch the child worker and see that it works correctly:
        pw.watch(childWorker)
        childWorker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        childWorker.tell(.throwError(error: WorkerError.error(code: 418))) // BOOM!

        // the worker, should have terminated due to the error:
        try pw.expectTerminated(childWorker)

        // even though the worker crashed, the parent is still alive (!)
        let stillAlive = "still alive"
        healthyMaster.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "still alive"))
    }

    func test_worker_FaultDomain_crashOnlyWorkerOnDivisionByZero() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = testKit.spawnTestProbe(name: "testProbe-master")
        let pw: ActorTestProbe<Int> = testKit.spawnTestProbe(name: "testProbe-faultyWorker")

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster", props: isolateFaultDomainProps)

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell(spawnFaultyWorkerCommand)
        guard case let .spawned(childWorker) = try pm.expectMessage() else { fatalError("did not receive expected message") }

        // watch the child worker and see that it works correctly:
        pw.watch(childWorker)
        childWorker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        childWorker.tell(.work(n: 100, divideBy: 0)) // BOOM!
        try pw.expectNoMessage(for: .milliseconds(200)) // code after the divide-by-zero should not be allowed to execute

        // the worker, should have terminated due to the error:
        let workerTerminated = try pw.expectTerminated(childWorker)
        pinfo("Good: \(workerTerminated)")

        // even though the worker crashed, the parent is still alive (!)
        let stillAlive = "still alive"
        healthyMaster.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "still alive"))
        pinfo("Good: Parent \(healthyMaster) still active.")

//        healthyMaster.tell(spawnFaultyWorkerCommand)
//        pinfo("Good: Parent \(healthyMaster) was able to spawn new worker under the same name (unregistering of dead child worked).")
//        guard case let .spawned(childWorkerReplacement) = try pm.expectMessage() else { fatalError("did not receive expected message") }
//        childWorkerReplacement.path.shouldEqual(childWorker.path) // same path
//        childWorkerReplacement.shouldNotEqual(childWorker) // NOT same identity

//        childWorkerReplacement.tell(.work(n: 1000, divideBy: 100))
//        try pw.expectMessage(10)
//        // FIXME this is not complete
    }

    func test_crashOutsideOfActor_shouldStillFailLikeUsual() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function), can't that a fatalError() kills the process, it would kill the test suite; To see it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \\(#function), can't that a fatalError() kills the process, it would kill the test suite; To see it crash, run with 'test -Xswiftc=\"-DSACT_TESTS_CRASH\"'"

        fatalError("Boom like usual!")
        // this MUST NOT trigger Swift Distributed Actors failure handling, we are not inside of an actor!
    }

}

