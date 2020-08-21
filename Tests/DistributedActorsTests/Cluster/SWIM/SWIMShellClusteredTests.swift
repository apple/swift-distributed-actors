//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers // for TimeSource
import DistributedActorsTestKit
import Foundation
import XCTest
import SWIM

final class SWIMShellClusteredTests: ClusteredActorSystemsXCTestCase {
    var firstClusterProbe: ActorTestProbe<ClusterShell.Message>!
    var secondClusterProbe: ActorTestProbe<ClusterShell.Message>!

    func setUpFirst(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let first = super.setUpNode("first", modifySettings)
        self.firstClusterProbe = self.testKit(first).spawnTestProbe()
        return first
    }

    func setUpSecond(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let second = super.setUpNode("second", modifySettings)
        self.secondClusterProbe = self.testKit(second).spawnTestProbe()
        return second
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.filterActorPaths = ["/user/SWIM"] // the mocked one
        // settings.filterActorPaths = ["/system/cluster/swim"] // in case we test against the real one
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: LHA probe modifications

    func test_swim_shouldIncreaseProbeInterval_whenHighMultiplier() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let maxLocalHealthMultiplier = 100
        let ref = try first.spawn(
            "SWIM",
            SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref) { settings in
                settings.lifeguard.maxLocalHealthMultiplier = maxLocalHealthMultiplier
                settings.pingTimeout = .microseconds(1)
                // interval should be configured in a way that multiplied by a low LHA counter it will wail the test
                settings.probeInterval = .milliseconds(100)
            }
        )

        let dummyProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)

        // bump LHA multiplier to upper limit
        for nr in 1 ... maxLocalHealthMultiplier {
            ref.tell(.remote(.pingRequest(target: dummyProbe.ref, replyTo: ackProbe.ref, payload: .none, sequenceNumber: SWIM.SequenceNumber(nr))))
            try self.expectPing(on: dummyProbe, reply: false)
            try _ = ackProbe.expectMessage()
        }

        ref.tell(.local(.pingRandomMember))

        try _ = p.expectMessage()
        try p.expectNoMessage(for: .seconds(2))
    }

//    func test_swim_shouldNotIncreaseProbeInterval_whenLowMultiplier() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.maxLocalHealthMultiplier = 1
//                settings.pingTimeout = .microseconds(1)
//                // interval should be configured in a way that multiplied by a low LHA counter it will wail the test
//                settings.probeInterval = .milliseconds(100)
//            }
//        )
//
//        ref.tell(.local(.pingRandomMember))
//
//        try _ = p.expectMessage()
//        try _ = p.expectMessage()
//    }
//
//    func test_swim_shouldIncreasePingTimeout_whenHighMultiplier() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let maxLocalHealthMultiplier = 5
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.maxLocalHealthMultiplier = maxLocalHealthMultiplier
//                settings.pingTimeout = .milliseconds(500)
//                // interval should be configured in a way that multiplied by a low LHA counter it will wail the test
//                settings.probeInterval = .milliseconds(100)
//            }
//        )
//
//        let dummyProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//
//        // bump LHA multiplier to upper limit
//        for _ in 1 ... maxLocalHealthMultiplier {
//            ref.tell(.remote(.pingRequest(target: dummyProbe.ref, replyTo: ackProbe.ref, payload: .none, sequenceNumber: 13)))
//            try self.expectPing(on: dummyProbe, reply: false)
//            try _ = ackProbe.expectMessage(within: .seconds(6))
//        }
//
//        ref.tell(.remote(.pingRequest(target: dummyProbe.ref, replyTo: ackProbe.ref, payload: .none, sequenceNumber: 13)))
//        try self.expectPing(on: dummyProbe, reply: false)
//        try ackProbe.expectNoMessage(for: .seconds(1))
//    }
//
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Pinging nodes

    func test_swim_shouldRespondWithAckToPing() throws {
        let first = self.setUpFirst()
        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.ping(replyTo: p.ref, payload: .none, sequenceNumber: 13)))

        let response = try p.expectMessage()
        switch response {
        case .ack(let pinged, let incarnation, _, _):
            pinged.shouldEqual(ref.node)
            incarnation.shouldEqual(0)
        case let resp:
            throw p.error("Expected ack, but got \(resp)")
        }
    }

    func test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)

        let dummyProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let memberProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [memberProbe.ref], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.pingRequest(target: dummyProbe.ref, replyTo: ackProbe.ref, payload: .none, sequenceNumber: 13)))

        try self.expectPing(on: dummyProbe, reply: false)
        let response = try ackProbe.expectMessage()
        guard case .nack = response else {
            throw self.testKit(first).error("expected nack, but got \(response)")
        }
    }

    func test_swim_shouldPingRandomMember() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let p = self.testKit(second).spawnTestProbe(expecting: String.self)

        func behavior(postFix: String) -> Behavior<SWIM.Message> {
            .receive { context, message in
                switch message {
                case .remote(.ping(let replyTo, _, _)):
                    replyTo.tell(.ack(target: context.myself.node, incarnation: 0, payload: .none, sequenceNumber: 13))
                    p.tell("pinged:\(postFix)")
                default:
                    ()
                }

                return .same
            }
        }

        let refA = try second.spawn("SWIM-A", behavior(postFix: "A"))
        let remoteRefA = first._resolveKnownRemote(refA, onRemoteSystem: second)
        let refB = try second.spawn("SWIM-B", behavior(postFix: "B"))
        let remoteRefB = first._resolveKnownRemote(refB, onRemoteSystem: second)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [remoteRefA, remoteRefB], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))
        ref.tell(.local(.pingRandomMember))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

//    func test_swim_shouldPingSpecificMemberWhenRequested() throws {
//        let local = self.setUpFirst()
//
//        let memberProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Message.self)
//        let ackProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.PingResponse.self)
//
//        let ref = try local.spawn("SWIM", SWIMActorShell.swimBehavior(members: [memberProbe.ref], clusterRef: self.firstClusterProbe.ref))
//
//        ref.tell(.remote(.pingRequest(target: memberProbe.ref, replyTo: ackProbe.ref, payload: .none, sequenceNumber: 13)))
//
//        try self.expectPing(on: memberProbe, reply: true)
//        let response = try ackProbe.expectMessage()
//
//        switch response {
//        case .ack(let pinged, let incarnation, _):
//            pinged.shouldEqual(memberProbe.ref)
//            incarnation.shouldEqual(0)
//        case let resp:
//            throw self.testKit(local).error("Expected gossip, but got \(resp)")
//        }
//    }
//
//    // ==== ----------------------------------------------------------------------------------------------------------------
//    // MARK: Marking suspect nodes
//
//    func test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//
//        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))
//
//        ref.tell(.local(.pingRandomMember))
//
//        try self.expectPing(on: p, reply: false)
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: remoteProbeRef, on: ref, within: .seconds(1))
//    }
//
//    func test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//
//        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)
//
//        let refA = try first.spawn("SWIMRefA", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//        let refB = try first.spawn("SWIMRefB", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//
//        let behavior = SWIMActorShell.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
//            settings.pingTimeout = .milliseconds(50)
//        }
//
//        let ref = try first.spawn("SWIM", behavior)
//
//        ref.tell(.local(.pingRandomMember))
//
//        let forwardedPing = try probe.expectMessage()
//        guard case SWIM.Message.remote(.ping) = forwardedPing.message else {
//            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
//        }
//        let suspiciousRef = forwardedPing.recipient
//
//        let forwardedPingReq = try probe.expectMessage()
//        guard case SWIM.Message.remote(.pingRequest(target: suspiciousRef, _, _)) = forwardedPingReq.message else {
//            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
//        }
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: suspiciousRef, on: ref, within: .seconds(1))
//    }
//
//    func test_swim_shouldNotMarkSuspects_whenPingFailsButRequestedNodesSucceedToPing() throws {
//        let first = self.setUpFirst()
//
//        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)
//
//        let refA = try first.spawn("SWIMRefA", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//        let refB = try first.spawn("SWIMRefB", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//
//        let behavior = SWIMActorShell.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
//            settings.pingTimeout = .milliseconds(50)
//        }
//
//        let ref = try first.spawn("SWIM", behavior)
//
//        ref.tell(.local(.pingRandomMember))
//
//        let forwardedPing = try probe.expectMessage()
//        guard case SWIM.Message.remote(.ping) = forwardedPing.message else {
//            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
//        }
//        let suspiciousRef = forwardedPing.recipient
//
//        let forwardedPingReq = try probe.expectMessage()
//        guard case SWIM.Message.remote(.pingRequest(target: suspiciousRef, let replyTo, _)) = forwardedPingReq.message else {
//            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
//        }
//        replyTo.tell(.ack(target: suspiciousRef, incarnation: 0, payload: .none, sequenceNumber: 13))
//
//        try self.holdStatus(.alive(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
//    }
//
//    func test_swim_shouldMarkSuspectedMembersAsAlive_whenPingingSucceedsWithinSuspicionTimeout() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))
//
//        ref.tell(.local(.pingRandomMember))
//
//        try self.expectPing(on: p, reply: false)
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: remoteProbeRef, on: ref, within: .seconds(1))
//
//        ref.tell(.local(.pingRandomMember))
//
//        try self.expectPing(on: p, reply: true, incarnation: 1)
//
//        try self.awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
//    }
//
//    // FIXME: Can't seem to implement a hardened test like this...
//    func ignored_test_swim_shouldNotifyClusterAboutUnreachableNode_andThenReachableAgain() throws {
//        let first = self.setUpFirst { settings in
//            settings.cluster.swim.disabled = true // since we drive one manually
//        }
//        let second = self.setUpSecond { settings in
//            settings.cluster.swim.disabled = true // since we drive one manually
//        }
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//
//        let pingTimeout: TimeAmount = .milliseconds(100)
//        let timeSource = TestTimeSource()
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(
//                members: [remoteMemberRef],
//                clusterRef: self.firstClusterProbe.ref,
//                configuredWith: { settings in
//                    settings.lifeguard.timeSourceNanos = timeSource.now
//                    settings.lifeguard.suspicionTimeoutMin = .nanoseconds(3)
//                    settings.lifeguard.suspicionTimeoutMax = .nanoseconds(6)
//                    settings.pingTimeout = pingTimeout
//                }
//            )
//        )
//
//        // spin not-replying for more than timeoutPeriodsMax, such that the member will be marked as unreachable
//        for _ in 0 ..< SWIMSettings.default.lifeguard.suspicionTimeoutMax.nanoseconds + 100 {
//            ref.tell(.local(.pingRandomMember))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // should become unreachable
//        guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try self.firstClusterProbe.expectMessage() else {
//            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
//        }
//
//        // if it'd directly reply while unreachable (which is an "extended period suspect" really), it can come back alive
//        ref.tell(.local(.pingRandomMember))
//        try self.expectPing(on: p, reply: true, incarnation: 2)
//
//        // since we replied again with alive, should become reachable
//        try self.awaitStatus(.alive(incarnation: 2), for: remoteMemberRef, on: ref, within: .seconds(1))
//        guard case .command(.failureDetectorReachabilityChanged(_, .reachable)) = try self.firstClusterProbe.expectMessage() else {
//            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
//        }
//    }
//
//    func test_swim_shouldNotifyClusterAboutUnreachableNode_afterConfiguredSuspicionTimeout_andMarkDeadWhenConfirmed() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let timeSource = TestTimeSource()
//        let suspicionTimeoutPeriodsMax = 1000
//        let suspicionTimeoutPeriodsMin = 1
//
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.timeSourceNanos = timeSource.now
//                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
//                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
//            }
//        )
//
//        ref.tell(.local(.pingRandomMember))
//        try self.expectPing(on: p, reply: false)
//        timeSource.tick()
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: remoteMemberRef, on: ref, within: .seconds(1))
//
//        for _ in 0 ..< suspicionTimeoutPeriodsMax {
//            ref.tell(.local(.pingRandomMember))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // We need to trigger an additional ping to advance the protocol period
//        // and have the SWIM actor mark the remote node as dead
//        ref.tell(.local(.pingRandomMember))
//        timeSource.tick()
//
//        guard case .command(.failureDetectorReachabilityChanged(let address, .unreachable)) = try firstClusterProbe.expectMessage() else {
//            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(firstClusterProbe.lastMessage, orElse: "nil")`")
//        }
//        try self.holdStatus(.unreachable(incarnation: 0), for: remoteMemberRef, on: ref, within: .milliseconds(200))
//
//        ref.tell(.local(.confirmDead(address)))
//        try self.awaitStatus(.dead, for: remoteMemberRef, on: ref, within: .seconds(1))
//    }
//
//    func test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let maxIndependentSuspicions = 10
//        let suspicionTimeoutPeriodsMax = 1000
//        let suspicionTimeoutPeriodsMin = 1
//        let timeSource = TestTimeSource()
//
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.timeSourceNanos = timeSource.now
//                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
//                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
//                settings.lifeguard.maxIndependentSuspicions = maxIndependentSuspicions
//            }
//        )
//        ref.tell(.local(.pingRandomMember))
//        try self.expectPing(on: p, reply: false)
//        timeSource.tick()
//        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [firstNode])
//        ref.tell(.remote(.ping(replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))
//
//        try self.awaitStatus(suspectStatus, for: remoteMemberRef, on: ref, within: .seconds(1))
//        timeSource.tick()
//
//        for _ in 0 ..< suspicionTimeoutPeriodsMin {
//            ref.tell(.local(.pingRandomMember))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // We need to trigger an additional ping to advance the protocol period
//        // and have the SWIM actor mark the remote node as dead
//        ref.tell(.local(.pingRandomMember))
//        try self.firstClusterProbe.expectNoMessage(for: .seconds(1))
//    }
//
//    func test_swim_suspicionTimeout_decayWithIncomingSuspicions() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let maxIndependentSuspicions = 10
//        let suspicionTimeoutPeriodsMax = 1000
//        let suspicionTimeoutPeriodsMin = 1
//        let timeSource = TestTimeSource()
//
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.timeSourceNanos = timeSource.now
//                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
//                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
//                settings.lifeguard.maxIndependentSuspicions = maxIndependentSuspicions
//            }
//        )
//        ref.tell(.local(.pingRandomMember))
//        try self.expectPing(on: p, reply: false)
//        timeSource.tick()
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: remoteMemberRef, on: ref, within: .seconds(1))
//        timeSource.tick()
//
//        for _ in 0 ..< (suspicionTimeoutPeriodsMin + suspicionTimeoutPeriodsMax) / 2 {
//            ref.tell(.local(.pingRandomMember))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // We need to trigger an additional ping to advance the protocol period
//        ref.tell(.local(.pingRandomMember))
//        try self.firstClusterProbe.expectNoMessage(for: .seconds(1))
//        timeSource.tick()
//
//        let supectedByNodes = Set((1 ... maxIndependentSuspicions).map { UniqueNode(systemName: "test", host: "test", port: 12345, nid: UniqueNodeID(UInt32($0))) })
//
//        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: supectedByNodes)
//        ref.tell(.remote(.ping(replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))
//        // We do not increment the timesource to confirm that suspicion was triggered by the modified suspicion deadline
//        // and not incremented timer
//        try _ = ackProbe.expectMessage()
//
//        ref.tell(.local(.pingRandomMember))
//
//        guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try self.firstClusterProbe.expectMessage() else {
//            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
//        }
//    }
//
//    func test_swim_shouldMarkUnreachable_whenSuspectedByEnoughNodes_whenMinTimeoutReached() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let maxIndependentSuspicions = 10
//        let suspicionTimeoutPeriodsMax = 1000
//        let suspicionTimeoutPeriodsMin = 1
//        let timeSource = TestTimeSource()
//
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.lifeguard.timeSourceNanos = timeSource.now
//                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
//                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
//                settings.lifeguard.maxIndependentSuspicions = maxIndependentSuspicions
//            }
//        )
//        ref.tell(.local(.pingRandomMember))
//        try self.expectPing(on: p, reply: false)
//        timeSource.tick()
//
//        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let supectedByNodes = Set((1 ... maxIndependentSuspicions).map { UniqueNode(systemName: "test", host: "test", port: 12345, nid: UniqueNodeID(UInt32($0))) })
//        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: supectedByNodes)
//        ref.tell(.remote(.ping(replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))
//
//        try self.awaitStatus(suspectStatus, for: remoteMemberRef, on: ref, within: .seconds(1))
//        timeSource.tick()
//
//        for _ in 0 ..< suspicionTimeoutPeriodsMin {
//            ref.tell(.local(.pingRandomMember))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // We need to trigger an additional ping to advance the protocol period
//        ref.tell(.local(.pingRandomMember))
//        timeSource.tick()
//        guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try self.firstClusterProbe.expectMessage() else {
//            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
//        }
//    }
//
//    func test_swim_shouldNotifyClusterAboutUnreachableNode_whenUnreachableDiscoveredByOtherNode() throws {
//        let first = self.setUpFirst { settings in
//            // purposefully too large timeouts, we want the first node to be informed by the third node
//            // about the second node being unreachable/dead, and ensure that the first node also signals an
//            // unreachability event to the cluster upon such discovery.
//            settings.cluster.swim.lifeguard.suspicionTimeoutMax = .seconds(100)
//            settings.cluster.swim.lifeguard.suspicionTimeoutMin = .seconds(10)
//            settings.cluster.swim.pingTimeout = .seconds(3)
//        }
//        let second = self.setUpSecond()
//        let secondNode = second.cluster.uniqueNode
//        let third = self.setUpNode("third") { settings in
//            settings.cluster.swim.lifeguard.suspicionTimeoutMin = .nanoseconds(2)
//            settings.cluster.swim.lifeguard.suspicionTimeoutMax = .nanoseconds(2)
//            settings.cluster.swim.pingTimeout = .milliseconds(300)
//        }
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        third.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: [second.cluster.uniqueNode, third.cluster.uniqueNode])
//        try assertAssociated(second, withExactly: [first.cluster.uniqueNode, third.cluster.uniqueNode])
//        try assertAssociated(third, withExactly: [first.cluster.uniqueNode, second.cluster.uniqueNode])
//
//        let firstTestKit = self.testKit(first)
//        let p1 = firstTestKit.spawnTestProbe(expecting: Cluster.Event.self)
//        first.cluster.events.subscribe(p1.ref)
//
//        let thirdTestKit = self.testKit(third)
//        let p3 = thirdTestKit.spawnTestProbe(expecting: Cluster.Event.self)
//        third.cluster.events.subscribe(p3.ref)
//
//        try self.expectReachabilityInSnapshot(firstTestKit, node: secondNode, expect: .reachable)
//        try self.expectReachabilityInSnapshot(thirdTestKit, node: secondNode, expect: .reachable)
//
//        // kill the second node
//        second.shutdown()
//
//        try self.expectReachabilityEvent(thirdTestKit, p3, node: secondNode, expect: .unreachable)
//        try self.expectReachabilityEvent(firstTestKit, p1, node: secondNode, expect: .unreachable)
//
//        // we also expect the snapshot to include the right reachability information now
//        try self.expectReachabilityInSnapshot(firstTestKit, node: secondNode, expect: .unreachable)
//        try self.expectReachabilityInSnapshot(thirdTestKit, node: secondNode, expect: .unreachable)
//    }
//
//    /// Passed in `eventStreamProbe` is expected to have been subscribed to the event stream as early as possible,
//    /// as we want to expect the specific reachability event to be sent
//    private func expectReachabilityEvent(
//        _ testKit: ActorTestKit, _ eventStreamProbe: ActorTestProbe<Cluster.Event>,
//        node uniqueNode: UniqueNode, expect expected: Cluster.MemberReachability
//    ) throws {
//        let messages = try eventStreamProbe.fishFor(Cluster.ReachabilityChange.self, within: .seconds(10)) { event in
//            switch event {
//            case .reachabilityChange(let change):
//                return .catchComplete(change)
//            default:
//                return .ignore
//            }
//        }
//        messages.count.shouldEqual(1)
//        guard let change: Cluster.ReachabilityChange = messages.first else {
//            throw testKit.fail("Expected a reachability change, but did not get one on \(testKit.system.cluster.uniqueNode)")
//        }
//        change.member.uniqueNode.shouldEqual(uniqueNode)
//        change.member.reachability.shouldEqual(expected)
//    }
//
//    private func expectReachabilityInSnapshot(_ testKit: ActorTestKit, node: UniqueNode, expect expected: Cluster.MemberReachability) throws {
//        try testKit.eventually(within: .seconds(3)) {
//            let p11 = testKit.spawnEventStreamTestProbe(subscribedTo: testKit.system.cluster.events)
//            guard case .some(Cluster.Event.snapshot(let snapshot)) = try p11.maybeExpectMessage() else {
//                throw testKit.error("Expected snapshot, was: \(String(reflecting: p11.lastMessage))")
//            }
//
//            if let secondMember = snapshot.uniqueMember(node) {
//                if secondMember.reachability == expected {
//                    return
//                } else {
//                    throw testKit.error("Expected \(node) on \(testKit.system.cluster.uniqueNode) to be [\(expected)] but was: \(secondMember)")
//                }
//            } else {
//                pinfo("Unable to assert reachability of \(node) on \(testKit.system.cluster.uniqueNode) since membership did not contain it. Was: \(snapshot)")
//                () // it may have technically been removed already, so this is "fine"
//            }
//        }
//    }
//
//    // ==== ----------------------------------------------------------------------------------------------------------------
//    // MARK: Gossiping
//
//    func test_swim_shouldSendGossipInAck() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//
//        let memberProbe = self.testKit(second).spawnTestProbe("RemoteSWIM", expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(memberProbe.ref, onRemoteSystem: second)
//
//        let swimRef = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref))
//        swimRef.tell(.remote(.ping(replyTo: remoteProbeRef, payload: .none)))
//
//        let response: SWIM.PingResponse = try p.expectMessage()
//        switch response {
//        case .ack(_, _, .membership(let members)):
//            members.count.shouldEqual(2)
//            members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
//            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full address
//            // so we want to expect a full (with node) ref here:
//            members.shouldContain(SWIM.Member(ref: second._resolveKnownRemote(swimRef, onRemoteSystem: first), status: .alive(incarnation: 0), protocolPeriod: 0))
//        case let reply:
//            throw p.error("Expected gossip with membership, but got \(reply)")
//        }
//    }
//
//    func test_swim_shouldSendGossipInPing() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//
//        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//
//        let behavior = SWIMActorShell.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref) { settings in
//            settings.pingTimeout = .milliseconds(50)
//        }
//
//        let swimRef = try first.spawn("SWIM", behavior)
//        let remoteSwimRef = second._resolveKnownRemote(swimRef, onRemoteSystem: first)
//
//        swimRef.tell(.local(.pingRandomMember))
//
//        try self.expectPing(on: p, reply: false) {
//            switch $0 {
//            case .membership(let members):
//                members.shouldContain(SWIM.Member(ref: p.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
//                members.shouldContain(SWIM.Member(ref: remoteSwimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
//                members.count.shouldEqual(2)
//            case .none:
//                throw p.error("Expected gossip, but got `.none`")
//            }
//        }
//    }
//
//    func test_swim_shouldSendGossipInPingRequest() throws {
//        let first = self.setUpFirst()
//        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)
//
//        let refA = try first.spawn("SWIM-A", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//        let refB = try first.spawn("SWIM-B", self.forwardingSWIMBehavior(forwardTo: probe.ref))
//
//        let behavior = SWIMActorShell.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
//            settings.pingTimeout = .milliseconds(50)
//        }
//
//        let swimRef = try first.spawn("SWIM", behavior)
//
//        swimRef.tell(.local(.pingRandomMember))
//
//        let forwardedPing = try probe.expectMessage()
//        guard case SWIM.Message.remote(.ping) = forwardedPing.message else {
//            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
//        }
//        let suspiciousRef = forwardedPing.recipient
//
//        let forwardedPingReq = try probe.expectMessage()
//        guard case SWIM.Message.remote(.pingRequest(target: suspiciousRef, _, let gossip)) = forwardedPingReq.message else {
//            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
//        }
//
//        switch gossip {
//        case .membership(let members):
//            members.shouldContain(SWIM.Member(ref: refA, status: .alive(incarnation: 0), protocolPeriod: 0))
//            members.shouldContain(SWIM.Member(ref: refB, status: .alive(incarnation: 0), protocolPeriod: 0))
//            members.shouldContain(SWIM.Member(ref: swimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
//            members.count.shouldEqual(3)
//        case .none:
//            throw probe.error("Expected gossip, but got `.none`")
//        }
//    }
//
//    func test_swim_shouldSendGossipOnlyTheConfiguredNumberOfTimes() throws {
//        let first = self.setUpFirst()
//        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let memberProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)
//
//        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [memberProbe.ref], clusterRef: self.firstClusterProbe.ref))
//
//        for _ in 0 ..< SWIM.Settings.default.gossip.maxGossipCountPerMessage {
//            ref.tell(.remote(.ping(replyTo: p.ref, payload: .none)))
//
//            let response = try p.expectMessage()
//            switch response {
//            case .ack(_, _, .membership(let members)):
//                members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
//            case let resp:
//                throw p.error("Expected gossip, but got \(resp)")
//            }
//        }
//
//        ref.tell(.remote(.ping(replyTo: p.ref, payload: .none)))
//
//        let response = try p.expectMessage()
//        switch response {
//        case .ack(let pinged, let incarnation, .none):
//            pinged.shouldEqual(ref)
//            incarnation.shouldEqual(0)
//        case let resp:
//            throw self.testKit(first).error("Expected no gossip, but got \(resp)")
//        }
//    }
//
//    func test_swim_shouldAlwaysSendSuspicon_whenPingingSuspect() throws {
//        let first = self.setUpFirst()
//        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//        let memberProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)
//
//        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [memberProbe.ref: .suspect(incarnation: 0, suspectedBy: [first.cluster.uniqueNode.asSWIMNode])], clusterRef: self.firstClusterProbe.ref))
//
//        // iterate maxGossipCountPerMessage + 1 times
//        for _ in 0 ..< SWIM.Settings().gossip.maxGossipCountPerMessage + 1 {
//            ref.tell(.local(.pingRandomMember))
//            let response = try memberProbe.expectMessage()
//
//            switch response {
//            case .remote(.ping(_, .membership(let members))):
//                members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .suspect(incarnation: 0, suspectedBy: [first.cluster.uniqueNode]), protocolPeriod: 0))
//            case let resp:
//                throw p.error("Expected gossip, but got \(resp)")
//            }
//        }
//    }
//
//    func test_swim_shouldIncrementIncarnation_whenProcessSuspicionAboutSelf() throws {
//        let first = self.setUpFirst()
//        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//
//        let ref = try first.spawn("SWIM", SWIMActorShell.swimBehavior(members: [], clusterRef: self.firstClusterProbe.ref))
//
//        ref.tell(.remote(.ping(replyTo: p.ref, payload: .membership([SWIM.Member(ref: ref, status: .suspect(incarnation: 0, suspectedBy: [first.cluster.uniqueNode]), protocolPeriod: 0)]))))
//
//        let response = try p.expectMessage()
//
//        switch response {
//        case .ack(_, let incarnation, .membership(let members)):
//            members.shouldContain(SWIM.Member(ref: ref, status: .alive(incarnation: 1), protocolPeriod: 0))
//            incarnation.shouldEqual(1)
//        case let reply:
//            throw p.error("Expected ack with gossip, but got \(reply)")
//        }
//    }
//
//    func test_swim_shouldConvergeStateThroughGossip() throws {
//        let first = self.setUpFirst()
//        let second = self.setUpSecond()
//
//        let membershipProbe = self.testKit(first).spawnTestProbe(expecting: SWIM._MembershipState.self)
//        let pingProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//
//        var settings: SWIMSettings = .default
//        settings.probeInterval = .milliseconds(100)
//
//        let firstSwim: ActorRef<SWIM.Message> = try self.testKit(first)._eventuallyResolve(address: ._swim(on: first.cluster.uniqueNode))
//        let secondSwim: ActorRef<SWIM.Message> = try self.testKit(second)._eventuallyResolve(address: ._swim(on: second.cluster.uniqueNode))
//
//        let localRefRemote = second._resolveKnownRemote(firstSwim, onRemoteSystem: first)
//
//        secondSwim.tell(.remote(.pingRequest(target: localRefRemote, replyTo: pingProbe.ref, payload: .none)))
//
//        try self.testKit(first).eventually(within: .seconds(10)) {
//            firstSwim.tell(._testing(.getMembershipState(replyTo: membershipProbe.ref)))
//            let statusA = try membershipProbe.expectMessage(within: .seconds(1))
//
//            secondSwim.tell(._testing(.getMembershipState(replyTo: membershipProbe.ref)))
//            let statusB = try membershipProbe.expectMessage(within: .seconds(1))
//
//            guard statusA.membershipState.count == 2, statusB.membershipState.count == 2 else {
//                throw self.testKit(first).error("Expected count of both members to be 2, was [statusA=\(statusA.membershipState.count), statusB=\(statusB.membershipState.count)]")
//            }
//
//            for member in statusA.membershipState {
//                // there has to be a better way to do this, but that paths are
//                // different, because they reside on different nodes, so we
//                // compare only the segments, which are unique per instance
//                guard let (_, otherStatus) = statusB.membershipState.first(where: { $0.key.address.path.segments == ref.address.path.segments }) else {
//                    throw self.testKit(first).error("Did not get status for [\(ref)] in statusB")
//                }
//
//                guard otherStatus == status else {
//                    throw self.testKit(first).error("Expected status \(status) for [\(ref)] in statusB, but found \(otherStatus)")
//                }
//            }
//        }
//    }
//
//    func test_SWIMShell_shouldMonitorJoinedClusterMembers() throws {
//        let local = self.setUpFirst()
//        let remote = self.setUpSecond()
//
//        local.cluster.join(node: remote.cluster.uniqueNode.node)
//
//        let localSwim: ActorRef<SWIM.Message> = try self.testKit(local)._eventuallyResolve(address: ._swim(on: local.cluster.uniqueNode))
//        let remoteSwim: ActorRef<SWIM.Message> = try self.testKit(remote)._eventuallyResolve(address: ._swim(on: remote.cluster.uniqueNode))
//
//        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
//        try self.awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
//    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    struct ForwardedSWIMMessage: ActorMessage {
        let message: SWIM.Message
        let recipient: ActorRef<SWIM.Message>
    }

    func forwardingSWIMBehavior(forwardTo ref: ActorRef<ForwardedSWIMMessage>) -> Behavior<SWIM.Message> {
        .receive { context, message in
            ref.tell(.init(message: message, recipient: context.myself))
            return .same
        }
    }

    func expectPing(
        on probe: ActorTestProbe<SWIM.Message>, reply: Bool, incarnation: SWIM.Incarnation = 0,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column,
        assertPayload: (SWIM.GossipPayload) throws -> Void = { _ in
        }
    ) throws {
        switch try probe.expectMessage(file: file, line: line, column: column) {
        case .remote(.ping(let replyTo, let payload, let sequenceNumber)):
            try assertPayload(payload)
            if reply {
                replyTo.tell(.ack(target: probe.ref.node, incarnation: incarnation, payload: .none, sequenceNumber: sequenceNumber))
            }
        case let message:
            throw probe.error("Expected to receive `.ping`, received \(message) instead")
        }
    }

    func awaitStatus(
        _ status: SWIM.Status, for peer: ActorRef<SWIM.Message>,
        on swimShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM._MembershipState.self)

        try testKit.eventually(within: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(.getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()

            let otherStatus = membership.membershipState
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map { $0.status }
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func holdStatus(
        _ status: SWIM.Status, for peer: ActorRef<SWIM.Message>,
        on swimShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM._MembershipState.self)

        try testKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(.getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()
            let otherStatus = membership.membershipState
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map { $0.status }
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription)")
            }
        }
    }
}

extension SWIMActorShell {
    private static func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>], context: ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var memberStatus: [ActorRef<SWIM.Message>: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return self.makeSWIM(for: address, members: memberStatus, context: context, configuredWith: configure)
    }

    private static func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>: SWIM.Status], context: ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var settings = SWIM.Settings()
        configure(&settings)
        let instance = SWIM.Instance(
            settings: settings,
            myself: context.myself
        )
        for (member, status) in members {
            instance.addMember(member, status: status)
        }
        return instance
    }

    static func swimBehavior(members: [ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
    }) -> Behavior<SWIM.Message> {
        .setup { context in
            let swim = self.makeSWIM(for: context.address, members: members, context: context, configuredWith: configure)
            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
        }
    }

    static func swimBehavior(members: [ActorRef<SWIM.Message>: SWIM.Status], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
    }) -> Behavior<SWIM.Message> {
        .setup { context in
            let swim = self.makeSWIM(for: context.address, members: members, context: context, configuredWith: configure)
            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
        }
    }
}

class TestTimeSource {
    var currentTime: Atomic<Int64>

    /// starting from 1 to ensure .distantPast is already expired
    init(currentTime: Int64 = 1) {
        self.currentTime = Atomic(value: currentTime)
    }

    func now() -> Int64 {
        self.currentTime.load()
    }

    func tick() {
        _ = self.currentTime.add(1)
    }
}
