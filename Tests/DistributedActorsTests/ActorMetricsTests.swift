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
@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
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

    override func tearDown() {
        super.tearDown()
        self.metrics = nil
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    func test_serialization_reportsMetrics() throws {
        let first = self.setUpNode("first")
        let second = self.setUpNode("second")

        let ref: ActorRef<String> = try first.spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.deserialization]),
            Behavior.receive { _, _ in
                .same
            }
        )

        let remoteRef = second._resolve(ref: ref, onSystem: first)
        remoteRef.tell("Hello!")

        sleep(6)
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.deserialization.size")
        gauge.lastValue?.shouldEqual(6)
    }

    func test_mailboxCount_reportsMetrics() throws {
        let first = self.setUpNode("first")

        let one: ActorRef<String> = try first.spawn(
            "measuredActor",
            props: .metrics(group: "measuredActorGroup", measure: [.mailbox]),
            Behavior.receive { _, _ in .same }
        )

        for _ in 0...256 {
            one.tell("hello")
        }

        sleep(5)
        let gauge = try self.metrics.expectGauge("first.measuredActorGroup.mailbox.count")
        pprint("gauge.values = \(gauge.values)")
        gauge.values.shouldContain(256) // all messages en-queued
        gauge.lastValue.shouldEqual(0) // after processing we must always go back to zero
    }
}
