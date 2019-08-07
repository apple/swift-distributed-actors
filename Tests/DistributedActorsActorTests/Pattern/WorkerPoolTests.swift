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

// TODO "ActorGroup" perhaps could be better name?
final class WorkerPoolTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        system = ActorSystem(String(describing: type(of: self)))
        testKit = ActorTestKit(system)
    }

    override func tearDown() {
        system.shutdown()
    }

    func test_workerPool_registerNewlyStartedActors() throws {
        let workerKey = Receptionist.RegistrationKey(String.self, id: "request-workers")

        let pA: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pA")
        let pB: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pB")
        let pC: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pC")

        func worker(p: ActorTestProbe<String>) -> Behavior<String> {
            return .setup { context in
                context.system.receptionist.register(context.myself, key: workerKey) // could ask and await on the registration

                return .receive { context, work in
                    p.tell("work:\(work) at \(context.name)")
                    return .same
                }
            }
        }

        _ = try system.spawn(worker(p: pA), name: "worker-a")
        _ = try system.spawn(worker(p: pB), name: "worker-b")
        _ = try system.spawn(worker(p: pC), name: "worker-c")

        let workers = try WorkerPool.spawn(self.system, select: .dynamic(workerKey), name: "workers")

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

    func test_workerPool_removeDeadActors() throws {
        let workerKey = Receptionist.RegistrationKey(String.self, id: "request-workers")

        let pA: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pA")
        let pB: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pB")
        let pC: ActorTestProbe<String> = testKit.spawnTestProbe(name: "pC")

        func worker(p: ActorTestProbe<String>) -> Behavior<String> {
            return .setup { context in
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

        let workerA = try system.spawn(worker(p: pA), name: "worker-a")
        pA.watch(workerA)
        let workerB = try system.spawn(worker(p: pB), name: "worker-b")
        pB.watch(workerB)
        let workerC = try system.spawn(worker(p: pC), name: "worker-c")
        pC.watch(workerC)

        let workers = try WorkerPool.spawn(system, select: .dynamic(workerKey), name: "workersMayDie")

        workers.tell("a")
        workers.tell("b")
        workers.tell("c")
        try pA.expectMessage("work:a at worker-a")
        try pB.expectMessage("work:b at worker-b")
        try pC.expectMessage("work:c at worker-c")

        workerA.tell("stop")
        try pA.expectTerminated(workerA)
        // inherently this is racy, if a worker dies it may have taken a message with it
        // TODO: may introduce work-pulling pool which never would drop a message.

        // with A removed, the worker pool races to get the information about this death,
        // while we send new work to it -- it may happen that it sends to the dead A since it did not yet
        // receive the terminated; here we instead check that at least thr work is being handled by the other workers
        for i in 0...2 {
            try testKit.eventually(within: .seconds(1)) {
                workers.tell("after-A-dead-\(i)")
                let maybeBGotIt = try pB.maybeExpectMessage()
                let maybeCGotIt = try pC.maybeExpectMessage()

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
}
