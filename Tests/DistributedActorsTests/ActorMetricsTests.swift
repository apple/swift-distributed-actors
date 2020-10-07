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
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import Foundation
@testable import Metrics
@testable import CoreMetrics
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
            props: .metrics(group: "example", measure: [.serialization, .deserialization]),
            Behavior.receive { context, message in
                .same
            }
        )

        let remoteRef = second._resolve(ref: ref, onSystem: first)
        remoteRef.tell("Hello!")

        sleep(10)
        try self.metrics.expectCounter("kappa")
    }
}
