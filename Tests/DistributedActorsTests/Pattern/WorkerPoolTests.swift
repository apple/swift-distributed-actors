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
import DistributedActorsTestKit
import Foundation
import XCTest

// TODO: "ActorGroup" perhaps could be better name?
final class WorkerPoolTests: ActorSystemTestBase {
    func test_workerPool_registerNewlyStartedActors() throws {
        let workerKey = Receptionist.RegistrationKey(messageType: String.self, id: "request-workers")

        let pA: ActorTestProbe<String> = self.testKit.spawnTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.spawnTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.spawnTestProbe("pC")

        func worker(p: ActorTestProbe<String>) -> Behavior<String> {
            .setup { context in
                context.system.receptionist.register(context.myself, key: workerKey) // could ask and await on the registration

                return .receive { context, work in
                    p.tell("work:\(work) at \(context.name)")
                    return .same
                }
            }
        }

        _ = try self.system.spawn("worker-a", worker(p: pA))
        _ = try self.system.spawn("worker-b", worker(p: pB))
        _ = try self.system.spawn("worker-c", worker(p: pC))

        let workers = try WorkerPool.spawn(self.system, "workers", select: .dynamic(workerKey))

        workers.tell("a")
        workers.tell("b")
        workers.tell("c")
        workers.tell("d")
        workers.tell("e")
        workers.tell("f")
        workers.tell("g")
        workers.tell("h")
        // no more `c`

        try pA.expectMessage("work:a at worker-a")
        try pB.expectMessage("work:b at worker-b")
        try pC.expectMessage("work:c at worker-c")
        try pA.expectMessage("work:d at worker-a")
        try pB.expectMessage("work:e at worker-b")
        try pC.expectMessage("work:f at worker-c")
        try pA.expectMessage("work:g at worker-a")
        try pB.expectMessage("work:h at worker-b")
        try pC.expectNoMessage(for: .milliseconds(50))
    }

    func test_workerPool_dynamic_removeDeadActors() throws {
        let workerKey = Receptionist.RegistrationKey(messageType: String.self, id: "request-workers")

        let pA: ActorTestProbe<String> = self.testKit.spawnTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.spawnTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.spawnTestProbe("pC")

        func worker(p: ActorTestProbe<String>) -> Behavior<String> {
            .setup { context in
                context.system.receptionist.register(context.myself, key: workerKey) // could ask and await on the registration

                return .receive { context, work in
                    if work == "stop" {
                        return .stop
                    }
                    p.tell("work:\(work) at \(context.path.name)")
                    return .same
                }
            }
        }

        let workerA = try system.spawn("worker-a", worker(p: pA))
        pA.watch(workerA)
        let workerB = try system.spawn("worker-b", worker(p: pB))
        pB.watch(workerB)
        let workerC = try system.spawn("worker-c", worker(p: pC))
        pC.watch(workerC)

        let workers = try WorkerPool.spawn(self.system, "workersMayDie", select: .dynamic(workerKey))

        // since the workers joining the pool is still technically always a bit racy with the dynamic selection,
        // we try a few times to send a message and see it delivered at each worker. This would not be the case with a static selector.
        //
        // TODO: Go back to just `expectMessage(_: within:)` after #78 is fixed
        try self.testKit.eventually(within: .seconds(1)) {
            workers.tell("a")
            try pA.expectMessage("work:a at worker-a", within: .milliseconds(50))
        }
        try self.testKit.eventually(within: .seconds(1)) {
            workers.tell("b")
            try pB.expectMessage("work:b at worker-b", within: .milliseconds(50))
        }
        try self.testKit.eventually(within: .seconds(1)) {
            workers.tell("c")
            try pC.expectMessage("work:c at worker-c", within: .milliseconds(50))
        }
        workerA.tell("stop")
        try pA.expectTerminated(workerA)
        // clear all other messages to validate only the messages we send to the
        // pool after workerA has terminated
        pA.clearMessages()

        // inherently this is racy, if a worker dies it may have taken a message with it
        // TODO: may introduce work-pulling pool which never would drop a message.

        // with A removed, the worker pool races to get the information about this death,
        // while we send new work to it -- it may happen that it sends to the dead A since it did not yet
        // receive the terminated; here we instead check that at least thr work is being handled by the other workers
        for i in 0 ... 2 {
            try self.testKit.eventually(within: .seconds(1)) {
                workers.tell("after-A-dead-\(i)")
                let maybeBGotIt = try pB.maybeExpectMessage(within: .milliseconds(200))
                let maybeCGotIt = try pC.maybeExpectMessage(within: .milliseconds(200))

                // one of the workers should have handled it
                (maybeBGotIt != nil || maybeCGotIt != nil).shouldBeTrue()
                // but NOT both!
                (maybeBGotIt != nil && maybeCGotIt != nil).shouldBeFalse()
                let theMessage = maybeBGotIt ?? maybeCGotIt ?? "<none>"
                theMessage.shouldStartWith(prefix: "work:after-A-dead-\(i) at worker")
            }
        }
        try pA.expectNoMessage(for: .milliseconds(50))
    }

    func test_workerPool_ask() throws {
        let pA: ActorTestProbe<String> = self.testKit.spawnTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.spawnTestProbe("pB")

        func worker(p: ActorTestProbe<String>) -> Behavior<WorkerPoolQuestion> {
            .receive { context, work in
                p.tell("work:\(work.id) at \(context.path.name)")
                return .same
            }
        }

        let workerA = try system.spawn("worker-a", worker(p: pA))
        let workerB = try system.spawn("worker-b", worker(p: pB))

        let workers = try WorkerPool.spawn(self.system, "questioningTheWorkers", select: .static([workerA, workerB]))

        // since using a static pool, we know the messages will arrive; no need to wait for the receptionist dance:
        let answerA: AskResponse<String> = workers.ask(for: String.self, timeout: .seconds(1)) { WorkerPoolQuestion(id: "AAA", replyTo: $0) }
        let answerB: AskResponse<String> = workers.ask(for: String.self, timeout: .seconds(1)) { WorkerPoolQuestion(id: "BBB", replyTo: $0) }

        try self.testKit.eventually(within: .seconds(1)) {
            answerA._onComplete { res in
                pA.tell("\(res)")
            }
        }
        try self.testKit.eventually(within: .seconds(1)) {
            answerB._onComplete { res in
                pB.tell("\(res)")
            }
        }

        try pA.expectMessage("work:AAA at \(workerA.path.name)")
        try pB.expectMessage("work:BBB at \(workerB.path.name)")
    }

    struct WorkerPoolQuestion: ActorMessage {
        let id: String
        let replyTo: ActorRef<String>
    }

    func test_workerPool_static_removeDeadActors_terminateItselfWhenNoWorkers() throws {
        let pA: ActorTestProbe<String> = self.testKit.spawnTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.spawnTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.spawnTestProbe("pC")
        let pW: ActorTestProbe<String> = self.testKit.spawnTestProbe("pW")

        func worker(p: ActorTestProbe<String>) -> Behavior<String> {
            .receive { context, work in
                if work == "stop" {
                    return .stop
                }
                p.tell("work:\(work) at \(context.path.name)")
                return .same
            }
        }

        let workerA = try system.spawn("worker-a", worker(p: pA))
        pA.watch(workerA)
        let workerB = try system.spawn("worker-b", worker(p: pB))
        pB.watch(workerB)
        let workerC = try system.spawn("worker-c", worker(p: pC))
        pC.watch(workerC)

        let workers = try WorkerPool.spawn(self.system, "staticWorkersMayDie", select: .static([workerA, workerB, workerC]))
        pW.watch(workers._ref)

        // since using a static pool, we know the messages will arrive; no need to wait for the receptionist dance:
        workers.tell("a")
        try pA.expectMessage("work:a at worker-a")
        workers.tell("b")
        try pB.expectMessage("work:b at worker-b")
        workers.tell("c")
        try pC.expectMessage("work:c at worker-c")

        workerA.tell("stop")
        try pA.expectTerminated(workerA)

        for i in 0 ... 2 {
            try self.testKit.eventually(within: .seconds(1)) {
                workers.tell("after-A-dead-\(i)")
                let maybeBGotIt = try pB.maybeExpectMessage(within: .milliseconds(200))
                let maybeCGotIt = try pC.maybeExpectMessage(within: .milliseconds(200))

                // one of the workers should have handled it
                (maybeBGotIt != nil || maybeCGotIt != nil).shouldBeTrue()
                // but NOT both!
                (maybeBGotIt != nil && maybeCGotIt != nil).shouldBeFalse()
                let theMessage = maybeBGotIt ?? maybeCGotIt ?? "<none>"
                theMessage.shouldStartWith(prefix: "work:after-A-dead-\(i) at worker")
            }
        }
        try pA.expectNoMessage(for: .milliseconds(50))

        // we continue with stopping all remaining workers, after which the pool should terminate itself

        workerB.tell("stop")
        try pB.expectTerminated(workerB)
        workerC.tell("stop")
        try pC.expectTerminated(workerC)

        try pW.expectTerminated(workers._ref)
    }

    func test_workerPool_static_throwOnEmptyInitialSet() throws {
        let error = shouldThrow {
            let _: WorkerPoolRef<Never> = try WorkerPool.spawn(system, "wrongConfigPool", select: .static([]))
        }

        "\(error)".shouldContain("Illegal empty collection passed to `.static` worker pool")
    }
}
