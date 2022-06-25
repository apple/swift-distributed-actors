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

import Atomics
@testable import CoreMetrics
import Distributed
@testable import DistributedActors
import DistributedActorsConcurrencyHelpers // for TimeSource
import DistributedActorsTestKit
import Foundation
@testable import Metrics
@testable import SWIM
import XCTest

final class SWIMShellClusteredTests: ClusteredActorSystemsXCTestCase {
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

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = ["/user/swim"]
    }

    func setUpFirst(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        await super.setUpNode("first", modifySettings)
    }

    func setUpSecond(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        await super.setUpNode("second", modifySettings)
    }

    func setUpThird(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        await super.setUpNode("third", modifySettings)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LHA probe modifications

    func test_swim_shouldNotIncreaseProbeInterval_whenLowMultiplier() async throws {
        let firstNode = await self.setUpFirst() { settings in
            settings.swim.lifeguard.maxLocalHealthMultiplier = 1
            settings.swim.pingTimeout = .microseconds(1)
            // interval should be configured in a way that multiplied by a low LHA counter it fail wail the test
            settings.swim.probeInterval = .milliseconds(100)
        }
        let secondNode = await self.setUpSecond()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode)
        try assertAssociated(firstNode, withExactly: secondNode.cluster.uniqueNode)

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second])

        // SWIMActorShell's sendFirstRemotePing might have been triggered when the nodes
        // are associated. Reset so we get metrics just for the test call.
        (try await self.metrics.getSWIMCounter(second) { $0.messageInboundCount })?.reset()

        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
        }

        try await self.assertMessageInboundCount(of: second, atLeast: 2, within: .milliseconds(300))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Pinging nodes

    func test_swim_shouldRespondWithAckToPing() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }

        let originPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)
        let response = try await first.ping(origin: originPeer, payload: .none, sequenceNumber: 13)

        guard case .ack(let pinged, let incarnation, _, _) = response else {
            throw testKit(firstNode).fail("Expected ack, but got \(response)")
        }

        (pinged as! SWIMActorShell).shouldEqual(first)
        incarnation.shouldEqual(0)
    }

    func test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()
        let thirdNode = await self.setUpThird()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        thirdNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        try assertAssociated(firstNode, withExactly: secondNode.cluster.uniqueNode)

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }
        guard let third = thirdNode._cluster?._swimShell else {
            throw testKit(thirdNode).fail("SWIM shell of [\(thirdNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second, third])

        // FIXME: use a non-responsive test probe instead of real system
        // Down the node so it doesn't respond to ping
        thirdNode.shutdown()
        try await self.ensureNodes(.removed, on: secondNode, nodes: thirdNode.cluster.uniqueNode)

        let originPeer = try SWIMActorShell.resolve(id: first.id._asRemote, using: secondNode)
        let targetPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: secondNode)
        // `first` pings `third` through `second`. `third` is down so `second` will return nack for ping request.
        let response = try await second.pingRequest(target: targetPeer, pingRequestOrigin: originPeer, payload: .none, sequenceNumber: 13)

        guard case .nack = response else {
            throw testKit(firstNode).fail("Expected nack, but got \(response)")
        }
    }

    func test_swim_shouldPingRandomMember() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()
        let thirdNode = await self.setUpThird()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        thirdNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        try assertAssociated(firstNode, withExactly: secondNode.cluster.uniqueNode)

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }
        guard let third = thirdNode._cluster?._swimShell else {
            throw testKit(thirdNode).fail("SWIM shell of [\(thirdNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second, third])

        // SWIMActorShell's sendFirstRemotePing might have been triggered when the nodes
        // are associated. Reset so we get metrics just for the test calls.
        (try await self.metrics.getSWIMCounter(second) { $0.messageInboundCount })?.reset()
        (try await self.metrics.getSWIMCounter(third) { $0.messageInboundCount })?.reset()

        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
        }

        // `first` should send ping to both `second` and `third` after two ticks
        try await withThrowingTaskGroup(of: Void.self) { group in
            for swimShell in [second, third] {
                group.addTask {
                    try await self.assertMessageInboundCount(of: swimShell, atLeast: 1, within: .seconds(2))
                }
            }
            // loop explicitly to propagagte any error that might have been thrown
            for try await _ in group {}
        }
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()
        let thirdNode = await self.setUpThird()

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }
        guard let third = thirdNode._cluster?._swimShell else {
            throw testKit(thirdNode).fail("SWIM shell of [\(thirdNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second, third])

        let originPeer = try SWIMActorShell.resolve(id: first.id._asRemote, using: secondNode)
        let targetPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: secondNode)
        // `first` pings `third` through `second`
        let response = try await second.pingRequest(target: targetPeer, pingRequestOrigin: originPeer, payload: .none, sequenceNumber: 13)

        guard case .ack(let pinged, let incarnation, _, _) = response else {
            throw testKit(firstNode).fail("Expected ack, but got \(response)")
        }

        (pinged as! SWIMActorShell).shouldEqual(third)
        incarnation.shouldEqual(0)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Marking suspect nodes

    func test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        try assertAssociated(firstNode, withExactly: secondNode.cluster.uniqueNode)

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second])

        let targetPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)

        // FIXME: use a non-responsive test probe instead of faking response
        // Fake a failed ping
        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            _ = __secretlyKnownToBeLocal.handlePingResponse(
                response: .timeout(target: targetPeer, pingRequestOrigin: nil, timeout: .milliseconds(100), sequenceNumber: 13),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
        }

        try await self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [first.node]), for: targetPeer, on: first, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()
        let thirdNode = await self.setUpThird()

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }
        guard let third = thirdNode._cluster?._swimShell else {
            throw testKit(thirdNode).fail("SWIM shell of [\(thirdNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second, third])

        let throughPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)
        let targetPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: firstNode)

        // FIXME: use non-response test probes instead of faking responses
        // Fake a failed ping and ping request
        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            // `first` got .timeout when pinging `third`, so it sends ping request to `second` for `three`
            _ = __secretlyKnownToBeLocal.handlePingResponse(
                response: .timeout(target: targetPeer, pingRequestOrigin: nil, timeout: .milliseconds(100), sequenceNumber: 13),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )
            // `first` got .timeout from `second` for ping request
            __secretlyKnownToBeLocal.handlePingRequestResponse(
                response: .timeout(target: targetPeer, pingRequestOrigin: first, timeout: .milliseconds(100), sequenceNumber: 5),
                pinged: throughPeer
            )
        }

        // eventually it will ping/pingRequest and as all the pings (supposedly) time out it should mark as suspect
        try await self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [first.node]), for: targetPeer, on: first, within: .seconds(1))
    }

    func test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached() async throws {
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1
        let timeSource = TestTimeSource()

        let firstNode = await self.setUpFirst() { settings in
            settings.swim.timeSourceNow = timeSource.now
            settings.swim.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
            settings.swim.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
            settings.swim.lifeguard.maxIndependentSuspicions = maxIndependentSuspicions
        }
        let secondNode = await self.setUpSecond()
        let thirdNode = await self.setUpThird()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        thirdNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        try assertAssociated(firstNode, withExactly: [secondNode.cluster.uniqueNode, thirdNode.cluster.uniqueNode])
        try assertAssociated(secondNode, withExactly: [firstNode.cluster.uniqueNode, thirdNode.cluster.uniqueNode])

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }
        guard let third = thirdNode._cluster?._swimShell else {
            throw testKit(thirdNode).fail("SWIM shell of [\(thirdNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second, third])

        let originPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: secondNode)
        let targetPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)

        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
        }
        // FIXME: use a non-responsive test probe
//         try self.expectPing(on: probeOnSecond, reply: false)
        timeSource.tick()

        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [first.node])

        _ = try await first.ping(origin: originPeer, payload: .membership([SWIM.Member(peer: targetPeer, status: suspectStatus, protocolPeriod: 0)]), sequenceNumber: 1)

        try await self.awaitStatus(suspectStatus, for: targetPeer, on: first, within: .seconds(1))
        timeSource.tick()

//          for _ in 0 ..< suspicionTimeoutPeriodsMin {
//              _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
//                  __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
//              }
//              // FIXME: use a non-responsive test probe
//              try self.expectPing(on: probeOnSecond, reply: false)
//              timeSource.tick()
//          }
//
//          // We need to trigger an additional ping to advance the protocol period
//          // and have the SWIM actor mark the remote node as dead
//         _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
//             __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
//         }
//
//         // FIXME: would second end up with .dead status?
//         try await self.awaitStatus(.dead, for: targetPeer, on: first, within: .seconds(1))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Gossiping

    func test_swim_shouldSendGossipInAck() async throws {
        let firstNode = await self.setUpFirst()
        let secondNode = await self.setUpSecond()

        firstNode.cluster.join(node: secondNode.cluster.uniqueNode.node)
        try assertAssociated(firstNode, withExactly: secondNode.cluster.uniqueNode)
        try assertAssociated(secondNode, withExactly: firstNode.cluster.uniqueNode)

        guard let first = firstNode._cluster?._swimShell else {
            throw testKit(firstNode).fail("SWIM shell of [\(firstNode)] should not be nil")
        }
        guard let second = secondNode._cluster?._swimShell else {
            throw testKit(secondNode).fail("SWIM shell of [\(secondNode)] should not be nil")
        }

        try await self.configureSWIM(for: first, members: [second])

        let secondPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)
        let response = try await first.ping(origin: secondPeer, payload: .none, sequenceNumber: 1)

        guard case .ack(_, _, .membership(let members), _) = response else {
            throw testKit(firstNode).fail("Expected gossip with membership, but got \(response)")
        }

        members.count.shouldEqual(2)
        members.shouldContain(where: { ($0.peer as! SWIMActorShell) == secondPeer && $0.status == .alive(incarnation: 0) })
        members.shouldContain(where: { ($0.peer as! SWIMActorShell) == first && $0.status == .alive(incarnation: 0) })
    }

    func test_SWIMShell_shouldMonitorJoinedClusterMembers() async throws {
        let localNode = await self.setUpFirst()
        let remoteNode = await self.setUpSecond()

        localNode.cluster.join(node: remoteNode.cluster.uniqueNode.node)

        guard let local = localNode._cluster?._swimShell else {
            throw testKit(localNode).fail("SWIM shell of [\(localNode)] should not be nil")
        }
        guard let remote = remoteNode._cluster?._swimShell else {
            throw testKit(remoteNode).fail("SWIM shell of [\(remoteNode)] should not be nil")
        }

        let remotePeer = try SWIMActorShell.resolve(id: remote.id._asRemote, using: localNode)
        try await self.awaitStatus(.alive(incarnation: 0), for: remotePeer, on: local, within: .seconds(1))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    private func configureSWIM(for swimShell: SWIMActorShell, members: [SWIMActorShell]) async throws {
        var memberStatus: [SWIMActorShell: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        try await self.configureSWIM(for: swimShell, members: memberStatus)
    }

    private func configureSWIM(for swimShell: SWIMActorShell, members: [SWIMActorShell: SWIM.Status]) async throws {
        try await swimShell.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            try __secretlyKnownToBeLocal._configureSWIM { swim in
                for (member, status) in members {
                    let member = try SWIMActorShell.resolve(id: member.id._asRemote, using: swimShell.actorSystem)
                    _ = swim.addMember(member, status: status)
                }
            }
        }
    }

    private func assertMessageInboundCount(of swimShell: SWIMActorShell, atLeast: Int, within: Duration) async throws {
        // FIXME: with test probes we can control the exact number of messages (e.g., probe.expectMessage()),
        // but that's not easy with do with real systems so we check for inbound message count and do at-least
        // instead of exact comparisons.
        let testKit = self.testKit(swimShell.actorSystem)

        try await testKit.eventually(within: within) {
            guard let counter = try await self.metrics.getSWIMCounter(swimShell, { $0.messageInboundCount }) else {
                throw testKit.error("SWIM metrics \(swimShell.actorSystem).messageInboundCount should not be nil")
            }

            let total = counter.totalValue
            if total < atLeast {
                throw testKit.error("Expected \(swimShell.actorSystem).messageInboundCount to be at least \(atLeast), was: \(total)")
            }
        }
    }

    private func awaitStatus(
        _ status: SWIM.Status, for peer: SWIMActorShell,
        on swimShell: SWIMActorShell, within timeout: Duration,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) async throws {
        let testKit = self.testKit(swimShell.actorSystem)

        try await testKit.eventually(within: timeout, file: file, line: line, column: column) {
            let membership = await swimShell.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal._getMembershipState()
            } ?? []

            let otherStatus = membership
                .first(where: { $0.peer as! SWIMActorShell == peer })
                .map(\.status)

            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription); Membership: \(membership)", file: file, line: line)
            }
        }
    }
}

class TestTimeSource {
    let currentTime: UnsafeAtomic<UInt64>

    /// starting from 1 to ensure .distantPast is already expired
    init(currentTime: UInt64 = 1) {
        self.currentTime = .create(currentTime)
    }

    func now() -> DispatchTime {
        DispatchTime(uptimeNanoseconds: self.currentTime.load(ordering: .relaxed))
    }

    func tick() {
        _ = self.currentTime.loadThenWrappingIncrement(by: 100, ordering: .relaxed)
    }
}
