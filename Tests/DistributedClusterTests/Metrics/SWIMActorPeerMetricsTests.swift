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
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
@testable import DistributedCluster
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

    override func tearDown() async throws {
        try await super.tearDown()
        self.metrics = nil
        MetricsSystem.bootstrapInternal(NOOPMetricsHandler.instance)
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = ["/user/swim"]
    }

    func test_swimPeer_ping_shouldRemoteMetrics() async throws {
        let originNode = await setUpNode("origin") { settings in
            settings.swim.probeInterval = .seconds(30) // Don't let gossip interfere with the test
        }
        let targetNode = await setUpNode("target")

        originNode.cluster.join(endpoint: targetNode.cluster.endpoint)
        try assertAssociated(originNode, withExactly: targetNode.cluster.node)

        guard let origin = originNode._cluster?._swimShell else {
            throw testKit(originNode).fail("SWIM shell of [\(originNode)] should not be nil")
        }
        guard let target = targetNode._cluster?._swimShell else {
            throw testKit(targetNode).fail("SWIM shell of [\(targetNode)] should not be nil")
        }

        // SWIMActor's sendFirstRemotePing might have been triggered when the nodes
        // are associated. Reset so we get metrics just for our sendPing call.
        (try await self.metrics.getSWIMTimer(origin) { $0.pingResponseTime })?.reset()
        (try await self.metrics.getSWIMCounter(origin) { $0.messageOutboundCount })?.reset()

        let targetPeer = try SWIMActor.resolve(id: target.id._asRemote, using: originNode)

        _ = await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            await __secretlyKnownToBeLocal.sendPing(
                to: targetPeer,
                payload: .none,
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil,
                timeout: .milliseconds(200),
                sequenceNumber: 1
            )
        }

        guard let timer = try await self.metrics.getSWIMTimer(origin, { $0.pingResponseTime }) else {
            throw testKit(originNode).fail("SWIM metrics pingResponseTime should not be nil")
        }
        pinfo("Recorded \(timer): \(String(reflecting: timer.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timer.label.shouldEqual("origin.cluster.swim.roundTripTime.ping")
        timer.lastValue!.shouldBeGreaterThan(0)

        guard let counter = try await self.metrics.getSWIMCounter(origin, { $0.messageOutboundCount }) else {
            throw testKit(originNode).fail("SWIM metrics messageOutboundCount should not be nil")
        }
        counter.totalValue.shouldEqual(1)
    }

    func test_swimPeer_pingRequest_shouldRemoteMetrics() async throws {
        let originNode = await setUpNode("origin") { settings in
            settings.swim.probeInterval = .seconds(30) // Don't let gossip interfere with the test
        }
        let targetNode = await setUpNode("target")
        let throughNode = await setUpNode("through")

        originNode.cluster.join(endpoint: throughNode.cluster.endpoint)
        targetNode.cluster.join(endpoint: throughNode.cluster.endpoint)
        try assertAssociated(originNode, withExactly: [targetNode.cluster.node, throughNode.cluster.node])

        guard let origin = originNode._cluster?._swimShell else {
            throw testKit(originNode).fail("SWIM shell of [\(originNode)] should not be nil")
        }
        guard let target = targetNode._cluster?._swimShell else {
            throw testKit(targetNode).fail("SWIM shell of [\(targetNode)] should not be nil")
        }
        guard let through = throughNode._cluster?._swimShell else {
            throw testKit(throughNode).fail("SWIM shell of [\(throughNode)] should not be nil")
        }

        // SWIMActor's sendFirstRemotePing might have been triggered when the nodes
        // are associated. Reset so we get metrics just for our sendPingRequest call.
        (try await self.metrics.getSWIMCounter(origin) { $0.messageOutboundCount })?.reset()

        let targetPeer = try SWIMActor.resolve(id: target.id._asRemote, using: originNode)
        let throughPeer = try SWIMActor.resolve(id: through.id._asRemote, using: originNode)

        let directive = SWIM.Instance<SWIMActor, SWIMActor, SWIMActor>.SendPingRequestDirective(
            target: targetPeer,
            timeout: .seconds(1),
            requestDetails: [
                .init(peerToPingRequestThrough: throughPeer, payload: .none, sequenceNumber: 1),
            ]
        )

        _ = await origin.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            await __secretlyKnownToBeLocal.sendPingRequests(directive)
        }

        guard let timerFirst = try await self.metrics.getSWIMTimer(origin, { $0.pingRequestResponseTimeFirst }) else {
            throw testKit(originNode).fail("SWIM metrics pingRequestResponseTimeFirst should not be nil")
        }
        pinfo("Recorded \(timerFirst): \(String(reflecting: timerFirst.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timerFirst.label.shouldEqual("origin.cluster.swim.roundTripTime.pingRequest")
        timerFirst.lastValue!.shouldBeGreaterThan(0)

        guard let timerAll = try await self.metrics.getSWIMTimer(origin, { $0.pingRequestResponseTimeAll }) else {
            throw testKit(originNode).fail("SWIM metrics pingRequestResponseTimeAll should not be nil")
        }
        pinfo("Recorded \(timerAll): \(String(reflecting: timerAll.lastValue.map { Duration.nanoseconds($0).prettyDescription }))")
        timerAll.label.shouldEqual("origin.cluster.swim.roundTripTime.pingRequest")
        timerAll.lastValue!.shouldBeGreaterThan(0)

        guard let counter = try await self.metrics.getSWIMCounter(origin, { $0.messageOutboundCount }) else {
            throw testKit(originNode).fail("SWIM metrics messageOutboundCount should not be nil")
        }
        counter.totalValue.shouldEqual(1)
    }
}

extension TestMetrics {
    func getSWIMTimer(_ swimShell: SWIMActor, _ body: (SWIM.Metrics.ShellMetrics) -> Timer) async throws -> TestTimer? {
        let timer: Timer? = try? await swimShell.whenLocal { myself in
            guard let shell = myself.metrics?.shell else { throw ClusterSystemError(.shuttingDown("")) }
            return body(shell)
        }

        guard let timer = timer else {
            return nil
        }

        return try self.expectTimer(timer)
    }

    func getSWIMCounter(_ swimShell: SWIMActor, _ body: (SWIM.Metrics.ShellMetrics) -> Counter) async throws -> TestCounter? {
        let counter: Counter? = try? await swimShell.whenLocal { myself -> Counter in
            guard let shell = myself.metrics?.shell else { throw ClusterSystemError(.shuttingDown("")) }
            return body(shell)
        }

        guard let counter = counter else {
            return nil
        }

        return try self.expectCounter(counter)
    }
}
