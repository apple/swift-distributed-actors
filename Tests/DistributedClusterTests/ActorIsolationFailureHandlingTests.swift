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

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ActorIsolationFailureHandlingTests {
    private enum SimpleTestError: Error {
        case simpleError(reason: String)
    }

    enum SimpleProbeMessage: Equatable, _NotActuallyCodableMessage {
        case spawned(child: _ActorRef<FaultyWorkerMessage>)
        case echoing(message: String)
    }

    enum FaultyWorkerMessage: _NotActuallyCodableMessage {
        case work(n: Int, divideBy: Int)
        case throwError(error: Error)
    }

    enum WorkerError: Error {
        case error(code: Int)
    }

    func faultyWorkerBehavior(probe pw: _ActorRef<Int>) -> _Behavior<FaultyWorkerMessage> {
        .receive { context, message in
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
    func healthyBossBehavior(pm: _ActorRef<SimpleProbeMessage>, pw: _ActorRef<Int>) -> _Behavior<String> {
        .receive { context, message in
            switch message {
            case self.spawnFaultyWorkerCommand:
                let worker = try context._spawn("faultyWorker", self.faultyWorkerBehavior(probe: pw))
                pm.tell(.spawned(child: worker))
            default:
                pm.tell(.echoing(message: message))
            }
            return .same
        }
    }
    
    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    @Test
    func test_worker_crashOnlyWorkerOnPlainErrorThrow() throws {
        let pm: ActorTestProbe<SimpleProbeMessage> = self.testCase.testKit.makeTestProbe("testProbe-boss-1")
        let pw: ActorTestProbe<Int> = self.testCase.testKit.makeTestProbe("testProbeForWorker-1")
        
        let healthyBoss: _ActorRef<String> = try self.testCase.system._spawn("healthyBoss", self.healthyBossBehavior(pm: pm.ref, pw: pw.ref))
        
        // watch parent and see it spawn the worker:
        pm.watch(healthyBoss)
        healthyBoss.tell("spawnFaultyWorker")
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
        healthyBoss.tell(stillAlive)
        try pm.expectMessage(.echoing(message: "still alive"))
    }
}
