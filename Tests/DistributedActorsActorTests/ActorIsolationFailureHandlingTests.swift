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
    lazy var testKit: ActorTestKit = ActorTestKit(system: system)

    let isolateFaultDomainProps = Props().withFaultDomain(.isolate)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }

    private enum SimpleTestError: Error {
        case simpleError(reason: String)
    }

//    func test_master_spawnInFaultDomain_allowActorToFailButKeepProcessAlive() throws {
//        let p: ActorTestProbe<String> = ActorTestProbe(name: "p1", on: system)
//
//        let failOnThis = "boom!"
//        let throwThis: SimpleTestError = .simpleError(reason: failOnThis)
//
//        let faultyMasterBehavior: Behavior<String> = .receive { context, message in
//            if message == failOnThis {
//                throw throwThis
//            } else {
//                p.tell(message)
//            }
//            return .same
//        }
//        let faultyMaster: ActorRef<String> = try system.spawn(faultyMasterBehavior, name: "faultyMaster", props: isolateFaultDomainProps)
//
//        p.watch(faultyMaster)
//        faultyMaster.tell("hello")
//        try p.expectMessage("hello")
//        // since we got hello back, watch was surely also processed
//
//        faultyMaster.tell(failOnThis)
//
//        try p.expectTerminated(faultyMaster)
//
//    }

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

    func healthyMasterBehavior(pm: ActorRef<SimpleProbeMessages>, pw: ActorRef<Int>) -> Behavior<String> {
        return .setup { context in
            let worker = try context.spawn(self.faultyWorkerBehavior(probe: pw), name: "faultyWorker")
            pm.tell(.spawned(child: worker))

            // TODO: make sure returning .same from setup is not allowed
            return .receiveMessage { message in
                pm.tell(.echoing(message: message))
                return .same
            }
        }
    }

    func test_worker_crashOnlyWorkerOnPlainErrorThrow() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = ActorTestProbe(name: "testProbe-master", on: system)
        let pw: ActorTestProbe<Int> = ActorTestProbe(name: "testProbe-faultyWorker", on: system)

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster")

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        guard case let .spawned(childWorker) = try pm.expectMessage() else { fatalError("did not receive expected message")}

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
        let pm: ActorTestProbe<SimpleProbeMessages> = ActorTestProbe(name: "testProbe-master", on: system)
        let pw: ActorTestProbe<Int> = ActorTestProbe(name: "testProbe-faultyWorker", on: system)

        let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(pm: pm.ref, pw: pw.ref),
            name: "healthyMaster", props: isolateFaultDomainProps)

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        guard case let .spawned(childWorker) = try pm.expectMessage() else { fatalError("did not receive expected message")}

        // watch the child worker and see that it works correctly:
        pw.watch(childWorker)
        childWorker.tell(.work(n: 100, divideBy: 10))
        try pw.expectMessage(10)

        // issue a message that will cause the worker to crash
        childWorker.tell(.work(n: 100, divideBy: 0)) // BOOM!

        // the worker, should have terminated due to the error:
        try pw.expectTerminated(childWorker)

        // even though the worker crashed, the parent is still alive (!)
        let stillAlive = "still alive"
        healthyMaster.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "stillAlive"))
    }

}

