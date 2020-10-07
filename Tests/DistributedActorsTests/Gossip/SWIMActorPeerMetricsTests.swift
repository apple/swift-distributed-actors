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
import SWIM
@testable import Metrics
import NIO
import XCTest

final class ActorMetricsSWIMActorPeerMetricsTests: ClusteredActorSystemsXCTestCase {
    var metrics: TestMetrics! = TestMetrics(verbose: true)

    override func setUp() {
        super.setUp()
        MetricsSystem.bootstrapInternal(self.metrics)
    }

    override func tearDown() {
        super.tearDown()
        self.metrics = nil
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    func test_swimPeer_ping_shouldRemoteMetrics() throws {
        let first = self.setUpNode("first")

        let peer: ActorRef<SWIM.Message> = try first.spawn("peer", .receive { context, message in
            switch message {
            case SWIM.Message.remote(.ping(let pingOrigin, _, _)):
                pingOrigin.ack(acknowledging: 1, target: context.myself, incarnation: 0, payload: .none)
            default:
                fatalError()
            }
            return .same
        })

        let origin = testKit(first).spawnTestProbe(expecting: SWIM.Message.self)
        let target = testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
        peer.ping(payload: .none, from: origin.ref, timeout: .seconds(2), sequenceNumber: 1) { result in
            switch result {
            case .success(let response):
                target.tell(response)
            default:
                fatalError("Got: \(result)")
            }
        }

        try target.expectMessage()
        let timer = try self.metrics.expectTimer("swim.roundTripTime.ping")
        pinfo("Recorded \(timer): \(timer.lastValue.map { TimeAmount.nanoseconds($0).prettyDescription })")
        timer.lastValue?.shouldBeGreaterThan(0)
    }

}
