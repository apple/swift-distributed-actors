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
@testable import DistributedActors
import DistributedActorsConcurrencyHelpers // for TimeSource
import DistributedActorsTestKit
import Foundation
@testable import SWIM
import XCTest

final class SWIMShellClusteredTests: ClusteredActorSystemsXCTestCase {
    var firstClusterProbe: ActorTestProbe<ClusterShell.Message>!
    var secondClusterProbe: ActorTestProbe<ClusterShell.Message>!

    func setUpFirst(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        let first = await super.setUpNode("first", modifySettings)
        self.firstClusterProbe = self.testKit(first).makeTestProbe()
        return first
    }

    func setUpSecond(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        let second = await super.setUpNode("second", modifySettings)
        self.secondClusterProbe = self.testKit(second).makeTestProbe()
        return second
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = ["/user/SWIM"] // the mocked one
        // settings.filterActorPaths = ["/system/cluster/swim"] // in case we test against the real one
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LHA probe modifications

    func test_swim_shouldNotIncreaseProbeInterval_whenLowMultiplier() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let ref = try first._spawn(
            "SWIM",
            SWIMActorShell.swimTestBehavior(members: [probeOnSecond.ref], clusterRef: self.firstClusterProbe.ref) { settings in
                settings.lifeguard.maxLocalHealthMultiplier = 1
                settings.pingTimeout = .microseconds(1)
                // interval should be configured in a way that multiplied by a low LHA counter it fail wail the test
                settings.probeInterval = .milliseconds(100)
            }
        )

        ref.tell(.local(.protocolPeriodTick))

        _ = try probeOnSecond.expectMessage()
        _ = try probeOnSecond.expectMessage()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Pinging nodes

    func test_swim_shouldRespondWithAckToPing() async throws {
        let first = await self.setUpFirst()
        let p = self.testKit(first).makeTestProbe(expecting: SWIM.Message.self)

        let ref = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.ping(pingOrigin: p.ref, payload: .none, sequenceNumber: 13)))

        let response = try p.expectMessage()
        switch response {
        case .remote(.pingResponse(.ack(let pinged, let incarnation, _, _))):
            (pinged as! SWIM.Ref).shouldEqual(ref)
            incarnation.shouldEqual(0)
        case let resp:
            throw p.error("Expected ack, but got \(resp)")
        }
    }

    func test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)

        let dummyProbe = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let firstPeerProbe = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(first).makeTestProbe(expecting: SWIM.PingOriginRef.Message.self)

        let ref = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [firstPeerProbe.ref], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.pingRequest(target: dummyProbe.ref, pingRequestOrigin: ackProbe.ref, payload: .none, sequenceNumber: 13)))

        try self.expectPing(on: dummyProbe, reply: false)
        let response = try ackProbe.expectMessage()
        guard case .remote(.pingResponse(.nack)) = response else {
            throw self.testKit(first).error("expected nack, but got \(response)")
        }
    }

    func test_swim_shouldPingRandomMember() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpSecond()
        let third = await setUpNode("third")

        first.cluster.join(node: second.cluster.uniqueNode.node)
        third.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let p = self.testKit(second).makeTestProbe(expecting: String.self)

        func behavior(postFix: String) -> _Behavior<SWIM.Message> {
            .receive { context, message in
                switch message {
                case .remote(.ping(let replyTo, _, _)):
                    replyTo.tell(.remote(.pingResponse(.ack(target: context.myself, incarnation: 0, payload: .none, sequenceNumber: 13))))
                    p.tell("pinged:\(postFix)")
                default:
                    ()
                }

                return .same
            }
        }

        let refA = try second._spawn("SWIM-A", behavior(postFix: "A"))
        let refB = try third._spawn("SWIM-B", behavior(postFix: "B"))
        let ref = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.protocolPeriodTick))
        ref.tell(.local(.protocolPeriodTick))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpFirst()

        let secondProbe = self.testKit(second).makeTestProbe("SWIM-2", expecting: SWIM.Message.self)
        let ackProbe = self.testKit(second).makeTestProbe(expecting: SWIM.PingOriginRef.Message.self)

        let ref = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [secondProbe.ref], clusterRef: self.firstClusterProbe.ref))
        ref.tell(.remote(.pingRequest(target: secondProbe.ref, pingRequestOrigin: ackProbe.ref, payload: .none, sequenceNumber: 13)))

        try self.expectPing(on: secondProbe, reply: true)
        let response = try ackProbe.expectMessage()

        switch response {
        case .remote(.pingResponse(.ack(let pinged, let incarnation, _, _))):
            (pinged as! SWIM.Ref).shouldEqual(secondProbe.ref)
            incarnation.shouldEqual(0)
        case let resp:
            throw self.testKit(first).error("Expected gossip, but got \(resp)")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Marking suspect nodes

    func test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let firstSwim = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [probeOnSecond.ref], clusterRef: self.firstClusterProbe.ref))
        firstSwim.tell(.local(.protocolPeriodTick))

        try self.expectPing(on: probeOnSecond, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstSwim.node]), for: probeOnSecond.ref, on: firstSwim, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing() async throws {
        let systemSWIM = await self.setUpFirst()
        let systemA = await setUpNode("A")
        let systemB = await setUpNode("B")

        let probeA = self.testKit(systemA).makeTestProbe(expecting: ForwardedSWIMMessage.self)
        let refA = try systemA._spawn("SWIM-A", self.forwardingSWIMBehavior(forwardTo: probeA.ref))
        let probeB = self.testKit(systemB).makeTestProbe(expecting: ForwardedSWIMMessage.self)
        let refB = try systemB._spawn("SWIM-B", self.forwardingSWIMBehavior(forwardTo: probeB.ref))

        let swim = try systemSWIM._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.pingTimeout = .milliseconds(50)
        })
        swim.tell(.local(.protocolPeriodTick))

        // eventually it will ping/pingRequest and as none of the swims reply it should mark as suspect
        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [swim.node]), for: refA, on: swim, within: .seconds(3))
    }

    func test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached() async throws {
        let first = await self.setUpFirst()
        let firstNode = first.cluster.uniqueNode
        let second = await self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(probeOnSecond.ref, onRemoteSystem: second)
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1
        let timeSource = TestTimeSource()

        let ref = try first._spawn(
            "SWIM",
            SWIMActorShell.swimTestBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
                settings.timeSourceNow = timeSource.now
                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
                settings.lifeguard.maxIndependentSuspicions = maxIndependentSuspicions
            }
        )
        ref.tell(.local(.protocolPeriodTick))
        try self.expectPing(on: probeOnSecond, reply: false)
        timeSource.tick()
        let ackProbe = self.testKit(first).makeTestProbe(expecting: SWIM.Message.self)
        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [firstNode.asSWIMNode])
        ref.tell(.remote(.ping(pingOrigin: ackProbe.ref, payload: .membership([SWIM.Member(peer: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]), sequenceNumber: 1)))

        try self.awaitStatus(suspectStatus, for: remoteMemberRef, on: ref, within: .seconds(1))
        timeSource.tick()

        for _ in 0 ..< suspicionTimeoutPeriodsMin {
            ref.tell(.local(.protocolPeriodTick))
            try self.expectPing(on: probeOnSecond, reply: false)
            timeSource.tick()
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.protocolPeriodTick))
        try self.firstClusterProbe.expectNoMessage(for: .seconds(1))
    }

    /// Passed in `eventStreamProbe` is expected to have been subscribed to the event stream as early as possible,
    /// as we want to expect the specific reachability event to be sent
    private func expectReachabilityEvent(
        _ testKit: ActorTestKit, _ eventStreamProbe: ActorTestProbe<Cluster.Event>,
        node uniqueNode: UniqueNode, expect expected: Cluster.MemberReachability
    ) throws {
        let messages = try eventStreamProbe.fishFor(Cluster.ReachabilityChange.self, within: .seconds(10)) { event in
            switch event {
            case .reachabilityChange(let change):
                return .catchComplete(change)
            default:
                return .ignore
            }
        }
        messages.count.shouldEqual(1)
        guard let change: Cluster.ReachabilityChange = messages.first else {
            throw testKit.fail("Expected a reachability change, but did not get one on \(testKit.system.cluster.uniqueNode)")
        }
        change.member.uniqueNode.shouldEqual(uniqueNode)
        change.member.reachability.shouldEqual(expected)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Gossiping

    func test_swim_shouldSendGossipInAck() async throws {
        let first = await self.setUpFirst()
        let second = await self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
        let secondSwimProbe = self.testKit(second).makeTestProbe("RemoteSWIM", expecting: SWIM.Message.self)

        let swimRef = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [secondSwimProbe.ref], clusterRef: self.firstClusterProbe.ref))
        swimRef.tell(.remote(.ping(pingOrigin: probeOnSecond.ref, payload: .none, sequenceNumber: 1)))

        let response = try probeOnSecond.expectMessage()
        switch response {
        case .remote(.pingResponse(.ack(_, _, .membership(let members), _))):
            members.count.shouldEqual(2)
            members.shouldContain(SWIM.Member(peer: secondSwimProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full id
            // so we want to expect a full (with node) ref here:
            members.shouldContain(SWIM.Member(peer: swimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
        case let reply:
            throw probeOnSecond.error("Expected gossip with membership, but got \(reply)")
        }
    }

    func test_SWIMShell_shouldMonitorJoinedClusterMembers() async throws {
        let local = await self.setUpFirst()
        let remote = await self.setUpSecond()

        local.cluster.join(node: remote.cluster.uniqueNode.node)

        let localSwim: _ActorRef<SWIM.Message> = try self.testKit(local)._eventuallyResolve(id: ._swim(on: local.cluster.uniqueNode))
        let remoteSwim: _ActorRef<SWIM.Message> = try self.testKit(remote)._eventuallyResolve(id: ._swim(on: remote.cluster.uniqueNode))

        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
        try self.awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    struct ForwardedSWIMMessage: Codable {
        let message: SWIM.Message
        let recipient: _ActorRef<SWIM.Message>
    }

    func forwardingSWIMBehavior(forwardTo ref: _ActorRef<ForwardedSWIMMessage>) -> _Behavior<SWIM.Message> {
        .receive { context, message in
            ref.tell(.init(message: message, recipient: context.myself))
            return .same
        }
    }

    func expectPing(
        on probe: ActorTestProbe<SWIM.Message>, reply: Bool, incarnation: SWIM.Incarnation = 0,
        file: StaticString = #filePath, line: UInt = #line, column: UInt = #column,
        assertPayload: (SWIM.GossipPayload) throws -> Void = { _ in
        }
    ) throws {
        switch try probe.expectMessage(file: file, line: line, column: column) {
        case .remote(.ping(let replyTo, let payload, let sequenceNumber)):
            try assertPayload(payload)
            if reply {
                replyTo.tell(.remote(.pingResponse(.ack(target: probe.ref, incarnation: incarnation, payload: .none, sequenceNumber: sequenceNumber))))
            }
        case let message:
            throw probe.error("Expected to receive `.ping`, received \(message) instead")
        }
    }

    func awaitStatus(
        _ status: SWIM.Status, for peer: _ActorRef<SWIM.Message>,
        on swimShell: _ActorRef<SWIM.Message>, within timeout: Duration,
        file: StaticString = #filePath, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.makeTestProbe(expecting: [SWIM.Member].self)

        try testKit.eventually(within: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(._getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()

            let otherStatus = membership
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map(\.status)
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription); Membership: \(membership)", file: file, line: line)
            }
        }
    }

    func holdStatus(
        _ status: SWIM.Status, for peer: _ActorRef<SWIM.Message>,
        on swimShell: _ActorRef<SWIM.Message>, within timeout: Duration,
        file: StaticString = #filePath, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.makeTestProbe(expecting: [SWIM.Member].self)

        try testKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(._getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()
            let otherStatus = membership
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map(\.status)
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription)")
            }
        }
    }
}

extension SWIMActorShell {
    private static func makeSWIM(for id: ActorID, members: [SWIM.Ref], context: _ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var memberStatus: [SWIM.Ref: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return self.makeSWIM(for: id, members: memberStatus, context: context, configuredWith: configure)
    }

    private static func makeSWIM(for id: ActorID, members: [SWIM.Ref: SWIM.Status], context: _ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var settings = context.system.settings.swim
        configure(&settings)
        let instance = SWIM.Instance(settings: settings, myself: context.myself)
        for (member, status) in members {
            _ = instance.addMember(member, status: status)
        }
        return instance
    }

    static func swimTestBehavior(members: [_ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
    }) -> _Behavior<SWIM.Message> {
        .setup { context in
            let swim = self.makeSWIM(for: context.id, members: members, context: context, configuredWith: configure)
            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
        }
    }

    static func swimBehavior(members: [_ActorRef<SWIM.Message>: SWIM.Status], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
    }) -> _Behavior<SWIM.Message> {
        .setup { context in
            let swim = self.makeSWIM(for: context.id, members: members, context: context, configuredWith: configure)
            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
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
