//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
import XCTest

@testable import DistributedCluster

@Resolvable
protocol ResolvableCounter: DistributedActor where ActorSystem == ClusterSystem {
    distributed func increment(by amount: Int) -> Int
    distributed func reset()
}

distributed actor ConcreteCounter: ResolvableCounter {
    typealias ActorSystem = ClusterSystem

    private var value = 0

    distributed func increment(by amount: Int) -> Int {
        self.value += amount
        return self.value
    }

    distributed func reset() {
        self.value = 0
    }
}

final class ResolvableProtocolTests: ClusteredActorSystemsXCTestCase {
    func test_resolvableStub_localActor_shouldInvokeTheLocalActor() async throws {
        let system = await setUpNode("local")

        let counter = ConcreteCounter(actorSystem: system)
        let stub = try $ResolvableCounter.resolve(id: counter.id, using: system)

        let first = try await stub.increment(by: 2)
        first.shouldEqual(2)

        try await stub.reset()
        let afterReset = try await counter.increment(by: 1)
        afterReset.shouldEqual(1)
    }

    func test_resolvableStub_actorDiesAfterResolve_shouldThrowDeadLetter() async throws {
        let system = await setUpNode("local")

        var counter: ConcreteCounter? = ConcreteCounter(actorSystem: system)
        let stub = try $ResolvableCounter.resolve(id: counter!.id, using: system)
        counter = nil

        let error = try await shouldThrow {
            _ = try await stub.increment(by: 1)
        }
        XCTAssertEqual((error as? DeadLetterError)?.recipient, stub.id)

        let voidError = try await shouldThrow {
            try await stub.reset()
        }
        XCTAssertEqual((voidError as? DeadLetterError)?.recipient, stub.id)
    }

    func test_resolvableStub_remoteActor_shouldInvokeTheRemoteActor() async throws {
        let (local, remote) = await setUpPair()
        try await joinNodes(node: local, with: remote)

        let counter = ConcreteCounter(actorSystem: local)
        let stub = try $ResolvableCounter.resolve(id: counter.id, using: remote)

        let first = try await stub.increment(by: 2)
        first.shouldEqual(2)

        try await stub.reset()
        let afterReset = try await stub.increment(by: 5)
        afterReset.shouldEqual(5)
    }
}
