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
@testable import DistributedCluster
import Foundation
import XCTest

final class WorkerPoolRemoteTest: ClusteredActorSystemsXCTestCase {
    func test_workerPool_testRemoteActorReferencesAreHandledProperly() async throws {
        let (local, remote) = await self.setUpPair()
        let testKit = ActorTestKit(local)
        try await self.joinNodes(node: local, with: remote)

        let workerKey = DistributedReception.Key<GreeterDistributedWorker>(id: "request-workers")
        let workers = try await WorkerPool(
            settings: WorkerPoolSettings(
                selector: .dynamic(workerKey),
                strategy: .simpleRoundRobin
            ),
            actorSystem: local
        )
        let pA: ActorTestProbe<String> = testKit.makeTestProbe("pA")
        let pB: ActorTestProbe<String> = testKit.makeTestProbe("pB")
        let pC: ActorTestProbe<String> = testKit.makeTestProbe("pC")

        let workerA = await GreeterDistributedWorker(probe: pA, actorSystem: remote, key: workerKey)
        let workerB = await GreeterDistributedWorker(probe: pB, actorSystem: remote, key: workerKey)
        let workerC = await GreeterDistributedWorker(probe: pC, actorSystem: remote, key: workerKey)

        let workerProbes: [ClusterSystem.ActorID: ActorTestProbe<String>] = [
            workerA.id: pA,
            workerB.id: pB,
            workerC.id: pC,
        ]
        let workerIDs = [workerA.id, workerB.id, workerC.id]

        // Wait for all workers to be registered with the receptionist
        let finished = expectation(description: "all workers available")
        Task {
            while true {
                if try await workers.size == workerProbes.count {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3.0)

        // Submit work with all workers available
        for i in 0 ... 7 {
            _ = try await workers.submit(work: "\(i)")

            // We are submitting more work than there are workers
            let workerID = workerIDs[i % workerIDs.count]
            guard let probe = workerProbes[workerID] else {
                throw testKit.fail("Missing test probe for worker \(workerID)")
            }
            try probe.expectMessage("work:\(i) at \(workerID)")
        }
    }
}

/// Distributed actors should be non-private, otherwise `SerializationError(.unableToSummonTypeFromManifest)` will kick in
distributed actor GreeterDistributedWorker: DistributedWorker {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem
    typealias WorkItem = String
    typealias WorkResult = String

    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
    }

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem, key: DistributedReception.Key<GreeterDistributedWorker>) async {
        self.actorSystem = actorSystem
        self.probe = probe
        await self.actorSystem.receptionist.checkIn(self, with: key)
    }

    deinit {
        self.probe.tell("Greeter deinit")
    }

    distributed public func submit(work: WorkItem) async throws -> WorkResult {
        self.probe.tell("work:\(work) at \(self.id)")
        return "hello \(work)"
    }
}
