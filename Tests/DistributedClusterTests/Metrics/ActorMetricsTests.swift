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
import XCTest

final class ActorMetricsTests: ClusteredActorSystemsXCTestCase {
    var metrics: TestMetrics! = TestMetrics()

    override func setUp() {
        super.setUp()
        MetricsSystem.bootstrapInternal(self.metrics)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        self.metrics = nil
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    func test_serialization_reportsMetrics() async throws {
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): this crashes the cluster with a message on setup

        let first = await setUpNode("first")
        let second = await setUpNode("second")

        let ref: _ActorRef<String> = try first._spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.deserialization]),
            _Behavior.receive { _, _ in
                .same
            }
        )

        let remoteRef = second._resolve(ref: ref, onSystem: first)
        remoteRef.tell("Hello!")

        sleep(6)
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.deserialization.size")
        gauge.lastValue?.shouldEqual(6)
    }

    func test_mailboxCount_reportsMetrics() async throws {
        let first = await setUpNode("first")

        let one: _ActorRef<String> = try first._spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.mailbox]),
            _Behavior.receive { _, _ in .same }
        )

        for _ in 0 ... 256 {
            one.tell("hello")
        }

        sleep(5)
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.mailbox.count")
        // we can't really reliably test that we get to some "maximum" since the actor starts processing messages as they come in
        gauge.lastValue.shouldEqual(0) // after processing we must always go back to zero
    }
}
