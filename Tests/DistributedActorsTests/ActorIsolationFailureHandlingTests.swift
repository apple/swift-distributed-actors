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
import DistributedActorsTestTools
import Foundation
import XCTest

final class ActorIsolationFailureHandlingTests: XCTestCase {
    var system: ActorSystem!
    var testTools: ActorTestTools!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testTools = ActorTestTools(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
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
            case .work(let n, let divideBy): // Fault handling is not implemented
                pw.tell(n / divideBy)
                return .same
            case .throwError(let error):
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
                let worker = try context.spawn("faultyWorker", self.faultyWorkerBehavior(probe: pw))
                pm.tell(.spawned(child: worker))
            default:
                pm.tell(.echoing(message: message))
            }
            return .same
        }
    }

    func test_worker_crashOnlyWorkerOnPlainErrorThrow() throws {
        let pm: ActorTestProbe<SimpleProbeMessages> = self.testTools.spawnTestProbe("testProbe-master-1")
        let pw: ActorTestProbe<Int> = self.testTools.spawnTestProbe("testProbeForWorker-1")

        let healthyMaster: ActorRef<String> = try system.spawn("healthyMaster", self.healthyMasterBehavior(pm: pm.ref, pw: pw.ref))

        // watch parent and see it spawn the worker:
        pm.watch(healthyMaster)
        healthyMaster.tell("spawnFaultyWorker")
        guard case .spawned(let worker) = try pm.expectMessage() else { throw pm.error() }

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
}
