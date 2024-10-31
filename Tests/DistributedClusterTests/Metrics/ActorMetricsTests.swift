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

@testable import CoreMetrics
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
@testable import Metrics
import NIO
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
final class ActorMetricsTests {
    let metrics = TestMetrics()

    let testCase: ClusteredActorSystemsTestCase

    init() throws {
        self.testCase = try ClusteredActorSystemsTestCase()
        MetricsSystem.bootstrapInternal(self.metrics)
    }

    deinit {
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    @Test(.disabled("!!! Skipping test !!!")) // FIXME(distributed): this crashes the cluster with a message on setup
    func test_serialization_reportsMetrics() async throws {
        let first = await self.testCase.setUpNode("first")
        let second = await self.testCase.setUpNode("second")

        let ref: _ActorRef<String> = try first._spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.deserialization]),
            _Behavior.receive { _, _ in
                .same
            }
        )

        let remoteRef = second._resolve(ref: ref, onSystem: first)
        remoteRef.tell("Hello!")

        try await Task.sleep(for: .seconds(6))
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.deserialization.size")
        gauge.lastValue?.shouldEqual(6)
    }

    @Test
    func test_mailboxCount_reportsMetrics() async throws {
        let first = await self.testCase.setUpNode("first")

        let one: _ActorRef<String> = try first._spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.mailbox]),
            _Behavior.receive { _, _ in .same }
        )

        for _ in 0 ... 256 {
            one.tell("hello")
        }

        try await Task.sleep(for: .seconds(5))
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.mailbox.count")
        // we can't really reliably test that we get to some "maximum" since the actor starts processing messages as they come in
        gauge.lastValue.shouldEqual(0) // after processing we must always go back to zero
    }
}
