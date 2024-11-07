//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
import Foundation
import XCTest

@testable import DistributedCluster

// TODO: "ActorGroup" perhaps could be better name?
final class WorkerPoolTests: SingleClusterSystemXCTestCase {
    func test_workerPool_registerNewlyStartedActors() async throws {
        let workerKey = DistributedReception.Key(Greeter.self, id: "request-workers")

        let settings = WorkerPoolSettings(selector: .dynamic(workerKey))
        let workers = try await WorkerPool(settings: settings, actorSystem: system)

        let pA: ActorTestProbe<String> = self.testKit.makeTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.makeTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.makeTestProbe("pC")

        let workerA = await Greeter(probe: pA, actorSystem: self.system, key: workerKey)
        let workerB = await Greeter(probe: pB, actorSystem: self.system, key: workerKey)
        let workerC = await Greeter(probe: pC, actorSystem: self.system, key: workerKey)

        let workerProbes: [ClusterSystem.ActorID: ActorTestProbe<String>] = [
            workerA.id: pA,
            workerB.id: pB,
            workerC.id: pC,
        ]
        // Workers are sorted by id then selected round-robin
        let sortedWorkerIDs = Array(workerProbes.keys).sorted()

        // Wait for all workers to be registered with the receptionist
        let finished = expectation(description: "all workers available")
        Task {
            while true {
                if try await workers.size() == workerProbes.count {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3.0)

        // Submit work with all workers available
        for i in 0...7 {
            _ = try await workers.submit(work: "\(i)")

            // We are submitting more work than there are workers
            let workerID = sortedWorkerIDs[i % workerProbes.count]
            guard let probe = workerProbes[workerID] else {
                throw testKit.fail("Missing test probe for worker \(workerID)")
            }
            try probe.expectMessage("work:\(i) at \(workerID)")
        }
    }

    func test_workerPool_dynamic_removeDeadActors() async throws {
        throw XCTSkip("!!! Skipping test \(#function) !!!")  // FIXME(distributed): Pending fix for #831 to be able to terminate worker by setting it to nil

        let workerKey = DistributedReception.Key(Greeter.self, id: "request-workers")

        let workers = try await WorkerPool(selector: .dynamic(workerKey), actorSystem: system)

        let pA: ActorTestProbe<String> = self.testKit.makeTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.makeTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.makeTestProbe("pC")

        var workerA: Greeter? = await Greeter(probe: pA, actorSystem: self.system, key: workerKey)
        var workerB: Greeter? = await Greeter(probe: pB, actorSystem: self.system, key: workerKey)
        var workerC: Greeter? = await Greeter(probe: pC, actorSystem: self.system, key: workerKey)

        // !-safe since we initialize workers above
        let workerProbes: [ClusterSystem.ActorID: ActorTestProbe<String>] = [
            workerA!.id: pA,
            workerB!.id: pB,
            workerC!.id: pC,
        ]
        // Workers are sorted by id then selected round-robin
        var sortedWorkerIDs = Array(workerProbes.keys).sorted()

        // Wait for all workers to be registered with the receptionist
        let finished = expectation(description: "all workers available")
        Task {
            while true {
                if try await workers.size() == workerProbes.count {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3.0)

        // Submit work with all workers available
        for i in 0...2 {
            _ = try await workers.submit(work: "all-available-\(i)")

            let workerID = sortedWorkerIDs[i]
            guard let probe = workerProbes[workerID] else {
                throw testKit.fail("Missing test probe for worker \(workerID)")
            }
            try probe.expectMessage("work:all-available-\(i) at \(workerID)")
        }

        // Terminate workerA
        sortedWorkerIDs.removeAll { $0 == workerA!.id }
        workerA = nil
        try pA.expectMessage("Greeter deinit")

        // The remaining workers should take over
        for i in 0...2 {
            _ = try await workers.submit(work: "after-A-dead-\(i)")

            // We cannot be certain how round-robin position gets reset after A's termination,
            // so we don't enforce index check here.
            let maybeGotItResults = try sortedWorkerIDs.compactMap {
                guard let probe = workerProbes[$0] else {
                    throw testKit.fail("Missing test probe for worker \($0)")
                }
                return try probe.maybeExpectMessage(within: .milliseconds(200))
            }

            // Exactly one of the remaining workers should receive the work item
            (maybeGotItResults.count == 1).shouldBeTrue()
            (maybeGotItResults.first ?? "<none>").shouldStartWith(prefix: "work:after-A-dead-\(i) at")
        }

        // Terminate the rest of the workers
        workerB = nil
        try pB.expectMessage("Greeter deinit")
        workerC = nil
        try pC.expectMessage("Greeter deinit")

        // Register new worker
        let pD: ActorTestProbe<String> = self.testKit.makeTestProbe("pD")
        let workerD = await Greeter(probe: pD, actorSystem: self.system, key: workerKey)

        // WorkerPool should wait for D to join then assign work to it
        _ = try await workers.submit(work: "D-only")
        try pD.expectMessage("work:D-only at \(workerD.id)")
    }

    func test_workerPool_static_removeDeadActors_throwErrorWhenNoWorkers() async throws {
        let pA: ActorTestProbe<String> = self.testKit.makeTestProbe("pA")
        let pB: ActorTestProbe<String> = self.testKit.makeTestProbe("pB")
        let pC: ActorTestProbe<String> = self.testKit.makeTestProbe("pC")

        var workerA: Greeter? = Greeter(probe: pA, actorSystem: self.system)
        var workerB: Greeter? = Greeter(probe: pB, actorSystem: self.system)
        var workerC: Greeter? = Greeter(probe: pC, actorSystem: self.system)

        // !-safe since we initialize workers above
        let workers = try await WorkerPool(
            settings: .init(selector: .static([workerA!, workerB!, workerC!])),
            actorSystem: system
        )

        let workerProbes: [ClusterSystem.ActorID: ActorTestProbe<String>] = [
            workerA!.id: pA,
            workerB!.id: pB,
            workerC!.id: pC,
        ]
        // Workers are sorted by id then selected round-robin
        var sortedWorkerIDs = Array(workerProbes.keys).sorted()

        // Submit work with all workers available
        for i in 0...2 {
            _ = try await workers.submit(work: "all-available-\(i)")

            let workerID = sortedWorkerIDs[i]
            guard let probe = workerProbes[workerID] else {
                throw testKit.fail("Missing test probe for worker \(workerID)")
            }
            try probe.expectMessage("work:all-available-\(i) at \(workerID)")
        }

        // Terminate workerA
        sortedWorkerIDs.removeAll { $0 == workerA!.id }
        workerA = nil
        try pA.expectMessage("Greeter deinit")

        // The remaining workers should take over
        for i in 0...2 {
            _ = try await workers.submit(work: "after-A-dead-\(i)")

            // We cannot be certain how round-robin position gets reset after A's termination,
            // so we don't enforce index check here.
            let maybeGotItResults = try sortedWorkerIDs.compactMap {
                guard let probe = workerProbes[$0] else {
                    throw testKit.fail("Missing test probe for worker \($0)")
                }
                return try probe.maybeExpectMessage(within: .milliseconds(200))
            }

            // Exactly one of the remaining workers should receive the work item
            (maybeGotItResults.count == 1).shouldBeTrue()
            (maybeGotItResults.first ?? "<none>").shouldStartWith(prefix: "work:after-A-dead-\(i) at")
        }

        // Terminate the rest of the workers
        workerB = nil
        try pB.expectMessage("Greeter deinit")
        workerC = nil
        try pC.expectMessage("Greeter deinit")

        // WorkerPool now throws error on new work submission
        let error = try await shouldThrow {
            _ = try await workers.submit(work: "after-all-dead")
        }

        guard let workerPoolError = error as? WorkerPoolError,
            case .staticPoolExhausted(let errorMessage) = workerPoolError.underlying.error
        else {
            throw testKit.fail("Expected WorkerPoolError.staticPoolExhausted, got \(error)")
        }
        errorMessage.shouldContain("Static worker pool exhausted, all workers have terminated")
    }

    func test_workerPool_static_throwOnEmptyInitialSet() async throws {
        let error = try await shouldThrow {
            let _: WorkerPool<Greeter> = try await WorkerPool(selector: .static([]), actorSystem: system)
        }

        guard let workerPoolError = error as? WorkerPoolError,
            case .emptyStaticWorkerPool(let errorMessage) = workerPoolError.underlying.error
        else {
            throw testKit.fail("Expected WorkerPoolError.emptyStaticWorkerPool, got \(error)")
        }
        errorMessage.shouldContain("Illegal empty collection passed to `.static` worker pool")
    }
}

private distributed actor Greeter: DistributedWorker {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem
    typealias WorkItem = String
    typealias WorkResult = String

    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
    }

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem, key: DistributedReception.Key<Greeter>) async {
        self.actorSystem = actorSystem
        self.probe = probe
        await self.actorSystem.receptionist.checkIn(self, with: key)
    }

    deinit {
        self.probe.tell("Greeter deinit")
    }

    distributed func submit(work: WorkItem) async throws -> WorkResult {
        self.probe.tell("work:\(work) at \(self.id)")
        return "hello \(work)"
    }
}

extension Array where Element == ClusterSystem.ActorID {
    fileprivate mutating func sort() {
        self.sort(by: { l, r in l.description < r.description })
    }

    fileprivate func sorted() -> [Element] {
        self.sorted(by: { l, r in l.description < r.description })
    }
}
