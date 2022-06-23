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

@testable import CoreMetrics
@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
@testable import Metrics
import NIO
@testable import SWIM
import XCTest

final class ActorMetricsSWIMActorPeerMetricsTests: ClusteredActorSystemsXCTestCase {
    var metrics: TestMetrics! = TestMetrics()

    override func setUp() {
        MetricsSystem.bootstrapInternal(self.metrics)
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
        self.metrics = nil
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    func test_swimPeer_ping_shouldRemoteMetrics() async throws {
        let originNode = await setUpNode("origin")
        let targetNode = await setUpNode("target")

        guard let origin = originNode._cluster?._swimShell else {
            throw testKit(originNode).fail("SWIM shell of origin [\(originNode)] should be non nil")
        }
        guard let target = targetNode._cluster?._swimShell else {
            throw testKit(targetNode).fail("SWIM shell of target [\(targetNode)] should be non nil")
        }

        _ = await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            await __secretlyKnownToBeLocal.sendPing(
                to: target,
                payload: .none,
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil,
                timeout: .seconds(2),
                sequenceNumber: 1
            )
        }

        let timer = try self.metrics.expectTimer((
            await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.metrics.shell.pingResponseTime
            }
        )!)
        pinfo("Recorded \(timer): \(String(reflecting: timer.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timer.label.shouldEqual("origin.cluster.swim.roundTripTime.ping")
        timer.lastValue!.shouldBeGreaterThan(0)

        let counter = try self.metrics.expectCounter((
            await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.metrics.shell.messageOutboundCount
            }
        )!)
        counter.totalValue.shouldEqual(1)
    }

    func test_swimPeer_pingRequest_shouldRemoteMetrics() async throws {
        let originNode = await setUpNode("origin")
        let targetNode = await setUpNode("target")
        let throughNode = await setUpNode("through")

        guard let origin = originNode._cluster?._swimShell else {
            throw testKit(originNode).fail("SWIM shell of origin [\(originNode)] should be non nil")
        }
        guard let target = targetNode._cluster?._swimShell else {
            throw testKit(targetNode).fail("SWIM shell of target [\(targetNode)] should be non nil")
        }
        guard let through = throughNode._cluster?._swimShell else {
            throw testKit(throughNode).fail("SWIM shell of through [\(throughNode)] should be non nil")
        }

        let directive = SWIM.Instance.SendPingRequestDirective(
            target: target,
            timeout: .seconds(1),
            requestDetails: [
                .init(peerToPingRequestThrough: through, payload: .none, sequenceNumber: 1),
            ]
        )

        _ = await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            await __secretlyKnownToBeLocal.sendPingRequests(directive)
        }

        let timerFirst = try self.metrics.expectTimer((
            await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.metrics.shell.pingRequestResponseTimeFirst
            }
        )!)
        pinfo("Recorded \(timerFirst): \(String(reflecting: timerFirst.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timerFirst.label.shouldEqual("origin.cluster.swim.roundTripTime.pingRequest")
        timerFirst.lastValue!.shouldBeGreaterThan(0)

        let timerAll = try self.metrics.expectTimer((
            await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.metrics.shell.pingRequestResponseTimeAll
            }
        )!)
        pinfo("Recorded \(timerAll): \(String(reflecting: timerAll.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timerAll.label.shouldEqual("origin.cluster.swim.roundTripTime.pingRequest")
        timerAll.lastValue!.shouldBeGreaterThan(0)

        let counter = try self.metrics.expectCounter((
            await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.metrics.shell.messageOutboundCount
            }
        )!)
        counter.totalValue.shouldEqual(1)
    }
}
