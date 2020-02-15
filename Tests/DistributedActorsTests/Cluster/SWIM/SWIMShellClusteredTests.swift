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
import DistributedActorsTestKit
import Foundation
import XCTest

final class SWIMShellClusteredTests: ClusteredNodesTestBase {
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
//         settings.filterActorPaths = ["/system/cluster/swim"] // in case we test against the real one
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Pinging nodes

    func test_swim_shouldRespondWithAckToPing() throws {
        let first = self.setUpFirst()
        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.pinged.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
    }

    func test_swim_shouldPingRandomMember() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: String.self)

        func behavior(postFix: String) -> Behavior<SWIM.Message> {
            return .receive { context, message in
                switch message {
                case .remote(.ping(_, let replyTo, _)):
                    replyTo.tell(.init(pinged: context.myself, incarnation: 0, payload: .none))
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

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteRefA, remoteRefB], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))
        ref.tell(.local(.pingRandomMember))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() throws {
        let local = self.setUpFirst()

        let memberProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn("SWIM", self.swimBehavior(members: [memberProbe.ref], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.pingReq(target: memberProbe.ref, lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .none)))

        try self.expectPing(on: memberProbe, reply: true)

        let response = try ackProbe.expectMessage()
        response.pinged.shouldEqual(memberProbe.ref)
        response.incarnation.shouldEqual(0)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Marking suspect nodes

    func test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode]), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing() throws {
        let first = self.setUpFirst()

        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try first.spawn("SWIMRefA", self.forwardingSWIMBehavior(forwardTo: probe.ref))
        let refB = try first.spawn("SWIMRefB", self.forwardingSWIMBehavior(forwardTo: probe.ref))

        let behavior = self.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try first.spawn("SWIM", behavior)

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, _)) = forwardedPingReq.message else {
            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode]), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotMarkSuspects_whenPingFailsButRequestedNodesSucceedToPing() throws {
        let first = self.setUpFirst()

        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try first.spawn("SWIMRefA", self.forwardingSWIMBehavior(forwardTo: probe.ref))
        let refB = try first.spawn("SWIMRefB", self.forwardingSWIMBehavior(forwardTo: probe.ref))

        let behavior = self.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try first.spawn("SWIM", behavior)

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), let replyTo, _)) = forwardedPingReq.message else {
            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }
        replyTo.tell(.init(pinged: suspiciousRef, incarnation: 0, payload: .none))

        try self.holdStatus(.alive(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspectedMembersAsAlive_whenPingingSucceedsWithinSuspicionTimeout() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode]), for: remoteProbeRef, on: ref, within: .seconds(1))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: true, incarnation: 1)

        try self.awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    // FIXME: Can't seem to implement a hardened test like this...
    func ignored_test_swim_shouldNotifyClusterAboutUnreachableNode_andThenReachableAgain() throws {
        try shouldNotThrow {
            let first = self.setUpFirst { settings in
                settings.cluster.swim.disabled = true // since we drive one manually
            }
            let second = self.setUpSecond { settings in
                settings.cluster.swim.disabled = true // since we drive one manually
            }

            first.cluster.join(node: second.cluster.node.node)
            try assertAssociated(first, withExactly: second.cluster.node)

            let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
            let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)

            let pingTimeout: TimeAmount = .milliseconds(100)
            let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref, configuredWith: { settings in
                settings.failureDetector.suspicionTimeoutPeriodsMax = 3
                settings.failureDetector.pingTimeout = pingTimeout
            }))

            // spin not-replying for more than timeoutPeriodsMax, such that the member will be marked as unreachable
            for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMax + 100 {
                ref.tell(.local(.pingRandomMember))
                try self.expectPing(on: p, reply: false)
            }

            // should become unreachable
            guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try firstClusterProbe.expectMessage() else {
                throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(firstClusterProbe.lastMessage, orElse: "nil")`")
            }

            // if it'd directly reply while unreachable (which is an "extended period suspect" really), it can come back alive
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: true, incarnation: 2)

            // since we replied again with alive, should become reachable
            try self.awaitStatus(.alive(incarnation: 2), for: remoteMemberRef, on: ref, within: .seconds(1))
            guard case .command(.failureDetectorReachabilityChanged(_, .reachable)) = try firstClusterProbe.expectMessage() else {
                throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(firstClusterProbe.lastMessage, orElse: "nil")`")
            }
        }
    }

    func test_swim_shouldNotifyClusterAboutUnreachableNode_afterConfiguredSuspicionTimeout_andMarkDeadWhenConfirmed() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))
        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode]), for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMax {
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))

        guard case .command(.failureDetectorReachabilityChanged(let address, .unreachable)) = try firstClusterProbe.expectMessage() else {
            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(firstClusterProbe.lastMessage, orElse: "nil")`")
        }
        try self.holdStatus(.unreachable(incarnation: 0), for: remoteMemberRef, on: ref, within: .milliseconds(200))

        ref.tell(.local(.confirmDead(address)))
        try self.awaitStatus(.dead, for: remoteMemberRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.suspicionTimeoutPeriodsMin = suspicionTimeoutPeriodsMin
            settings.failureDetector.suspicionTimeoutPeriodsMax = suspicionTimeoutPeriodsMax
            settings.failureDetector.maxIndependentSuspicions = maxIndependentSuspicions
        })
        ref.tell(.local(.pingRandomMember))
        try self.expectPing(on: p, reply: false)
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)
        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode])
        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))

        try self.awaitStatus(suspectStatus, for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMin {
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))
        try self.firstClusterProbe.expectNoMessage(for: .seconds(1))
    }

    func test_swim_suspicionTimeout_decayWithIncomingSuspicions() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.suspicionTimeoutPeriodsMin = suspicionTimeoutPeriodsMin
            settings.failureDetector.suspicionTimeoutPeriodsMax = suspicionTimeoutPeriodsMax
            settings.failureDetector.maxIndependentSuspicions = maxIndependentSuspicions
        })
        ref.tell(.local(.pingRandomMember))
        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [SWIMInstance.testNode]), for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< (suspicionTimeoutPeriodsMin + suspicionTimeoutPeriodsMax) / 2 {
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        ref.tell(.local(.pingRandomMember))
        try self.firstClusterProbe.expectNoMessage(for: .seconds(1))
        let supectedByNodes = Set((1 ... maxIndependentSuspicions / 2).map { UniqueNode(systemName: "test", host: "test", port: 12345, nid: NodeID(UInt32($0))) })

        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)
        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: supectedByNodes)
        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))

        ref.tell(.local(.pingRandomMember))

        guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try self.firstClusterProbe.expectMessage() else {
            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
        }
    }

    func test_swim_shouldMarkUnreachable_whenSuspectedByEnoughNodes_whenMinTimeoutReached() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.suspicionTimeoutPeriodsMin = suspicionTimeoutPeriodsMin
            settings.failureDetector.suspicionTimeoutPeriodsMax = suspicionTimeoutPeriodsMax
            settings.failureDetector.maxIndependentSuspicions = maxIndependentSuspicions
        })
        ref.tell(.local(.pingRandomMember))
        try self.expectPing(on: p, reply: false)
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)
        let supectedByNodes = Set((1 ... maxIndependentSuspicions).map { UniqueNode(systemName: "test", host: "test", port: 12345, nid: NodeID(UInt32($0))) })
        let suspectStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: supectedByNodes)
        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .membership([SWIMMember(ref: remoteMemberRef, status: suspectStatus, protocolPeriod: 0)]))))

        try self.awaitStatus(suspectStatus, for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< suspicionTimeoutPeriodsMin {
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        ref.tell(.local(.pingRandomMember))
        guard case .command(.failureDetectorReachabilityChanged(_, .unreachable)) = try self.firstClusterProbe.expectMessage() else {
            throw self.testKit(first).fail("expected to receive `.command(.failureDetectorReachabilityChanged)`, but got `\(self.firstClusterProbe.lastMessage, orElse: "nil")`")
        }
    }

    func test_swim_shouldNotifyClusterAboutUnreachableNode_whenUnreachableDiscoveredByOtherNode() throws {
        let first = self.setUpFirst { settings in
            // purposefully too large timeouts, we want the first node to be informed by the third node
            // about the second node being unreachable/dead, and ensure that the first node also signals an
            // unreachability event to the cluster upon such discovery.
            settings.cluster.swim.failureDetector.suspicionTimeoutPeriodsMax = 100
            settings.cluster.swim.failureDetector.pingTimeout = .seconds(3)
        }
        let second = self.setUpSecond()
        let secondNode = second.cluster.node
        let third = self.setUpNode("third") { settings in
            settings.cluster.swim.failureDetector.suspicionTimeoutPeriodsMin = 2
            settings.cluster.swim.failureDetector.suspicionTimeoutPeriodsMax = 2
            settings.cluster.swim.failureDetector.pingTimeout = .milliseconds(300)
        }

        first.cluster.join(node: second.cluster.node.node)
        third.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: [second.cluster.node, third.cluster.node])
        try assertAssociated(second, withExactly: [first.cluster.node, third.cluster.node])
        try assertAssociated(third, withExactly: [first.cluster.node, second.cluster.node])

        let firstTestKit = self.testKit(first)
        let p1 = firstTestKit.spawnTestProbe(expecting: Cluster.Event.self)
        first.cluster.events.subscribe(p1.ref)

        let thirdTestKit = self.testKit(third)
        let p3 = thirdTestKit.spawnTestProbe(expecting: Cluster.Event.self)
        third.cluster.events.subscribe(p3.ref)

        try self.expectReachabilityInSnapshot(firstTestKit, node: secondNode, expect: .reachable)
        try self.expectReachabilityInSnapshot(thirdTestKit, node: secondNode, expect: .reachable)

        // kill the second node
        second.shutdown()

        try self.expectReachabilityEvent(thirdTestKit, p3, node: secondNode, expect: .unreachable)
        try self.expectReachabilityEvent(firstTestKit, p1, node: secondNode, expect: .unreachable)

        // we also expect the snapshot to include the right reachability information now
        try self.expectReachabilityInSnapshot(firstTestKit, node: secondNode, expect: .unreachable)
        try self.expectReachabilityInSnapshot(thirdTestKit, node: secondNode, expect: .unreachable)
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
            throw testKit.fail("Expected a reachability change, but did not get one on \(testKit.system.cluster.node)")
        }
        change.member.node.shouldEqual(uniqueNode)
        change.member.reachability.shouldEqual(expected)
    }

    private func expectReachabilityInSnapshot(_ testKit: ActorTestKit, node: UniqueNode, expect expected: Cluster.MemberReachability) throws {
        try testKit.eventually(within: .seconds(3)) {
            let p11 = testKit.spawnTestProbe(subscribedTo: testKit.system.cluster.events)
            guard case .some(Cluster.Event.snapshot(let snapshot)) = try p11.maybeExpectMessage() else {
                throw testKit.error("Expected snapshot, was: \(String(reflecting: p11.lastMessage))")
            }

            if let secondMember = snapshot.uniqueMember(node) {
                if secondMember.reachability == expected {
                    return
                } else {
                    throw testKit.error("Expected \(node) on \(testKit.system.cluster.node) to be [\(expected)] but was: \(secondMember)")
                }
            } else {
                pinfo("Unable to assert reachability of \(node) on \(testKit.system.cluster.node) since membership did not contain it. Was: \(snapshot)")
                () // it may have technically been removed already, so this is "fine"
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Gossiping

    func test_swim_shouldSendGossipInAck() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Ack.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)

        let memberProbe = self.testKit(second).spawnTestProbe("RemoteSWIM", expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(memberProbe.ref, onRemoteSystem: second)

        let swimRef = try first.spawn("SWIM", self.swimBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref))

        swimRef.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: remoteProbeRef, payload: .none)))

        let response: SWIM.Ack = try p.expectMessage()
        switch response.payload {
        case .membership(let members):
            members.count.shouldEqual(2)
            members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full address
            // so we want to expect a full (with node) ref here:
            members.shouldContain(SWIM.Member(ref: second._resolveKnownRemote(swimRef, onRemoteSystem: first), status: .alive(incarnation: 0), protocolPeriod: 0))
        case .none:
            throw p.error("Expected gossip, but got `.none`")
        }
    }

    func test_swim_shouldSendGossipInPing() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)

        let behavior = self.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let swimRef = try first.spawn("SWIM", behavior)
        let remoteSwimRef = second._resolveKnownRemote(swimRef, onRemoteSystem: first)

        swimRef.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: false) {
            switch $0 {
            case .membership(let members):
                members.shouldContain(SWIM.Member(ref: p.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
                members.shouldContain(SWIM.Member(ref: remoteSwimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
                members.count.shouldEqual(2)
            case .none:
                throw p.error("Expected gossip, but got `.none`")
            }
        }
    }

    func test_swim_shouldSendGossipInPingReq() throws {
        let first = self.setUpFirst()

        let probe = self.testKit(first).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try first.spawn("SWIM-A", self.forwardingSWIMBehavior(forwardTo: probe.ref))
        let refB = try first.spawn("SWIM-B", self.forwardingSWIMBehavior(forwardTo: probe.ref))

        let behavior = self.swimBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let swimRef = try first.spawn("SWIM", behavior)

        swimRef.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(first).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, let gossip)) = forwardedPingReq.message else {
            throw self.testKit(first).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }

        switch gossip {
        case .membership(let members):
            members.shouldContain(SWIM.Member(ref: refA, status: .alive(incarnation: 0), protocolPeriod: 0))
            members.shouldContain(SWIM.Member(ref: refB, status: .alive(incarnation: 0), protocolPeriod: 0))
            members.shouldContain(SWIM.Member(ref: swimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
            members.count.shouldEqual(3)
        case .none:
            throw probe.error("Expected gossip, but got `.none`")
        }
    }

    func test_swim_shouldSendGossipOnlyTheConfiguredNumberOfTimes() throws {
        let first = self.setUpFirst()
        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)
        let memberProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [memberProbe.ref], clusterRef: self.firstClusterProbe.ref))

        for _ in 0 ..< SWIM.Settings.default.gossip.maxGossipCountPerMessage {
            ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

            let response = try p.expectMessage()

            switch response.payload {
            case .membership(let members):
                members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            case .none:
                throw p.error("Expected gossip, but got `.none`")
            }
        }

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.pinged.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
        switch response.payload {
        case .membership:
            throw p.error("Expected no gossip, but got [\(response.payload)]")
        case .none:
            ()
        }
    }

    func test_swim_shouldConvergeStateThroughGossip() throws {
        try shouldNotThrow {
            let first = self.setUpFirst()
            let second = self.setUpSecond()

            let membershipProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.MembershipState.self)
            let pingProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)

            var settings: SWIMSettings = .default
            settings.failureDetector.probeInterval = .milliseconds(100)

            let firstSwim: ActorRef<SWIM.Message> = try self.testKit(first)._eventuallyResolve(address: ._swim(on: first.cluster.node))
            let secondSwim: ActorRef<SWIM.Message> = try self.testKit(second)._eventuallyResolve(address: ._swim(on: second.cluster.node))

            let localRefRemote = second._resolveKnownRemote(firstSwim, onRemoteSystem: first)

            secondSwim.tell(.remote(.pingReq(target: localRefRemote, lastKnownStatus: .alive(incarnation: 0), replyTo: pingProbe.ref, payload: .none)))

            try self.testKit(first).eventually(within: .seconds(10)) {
                firstSwim.tell(._testing(.getMembershipState(replyTo: membershipProbe.ref)))
                let statusA = try membershipProbe.expectMessage(within: .seconds(1))

                secondSwim.tell(._testing(.getMembershipState(replyTo: membershipProbe.ref)))
                let statusB = try membershipProbe.expectMessage(within: .seconds(1))

                guard statusA.membershipState.count == 2, statusB.membershipState.count == 2 else {
                    throw self.testKit(first).error("Expected count of both members to be 2, was [statusA=\(statusA.membershipState.count), statusB=\(statusB.membershipState.count)]")
                }

                for (ref, status) in statusA.membershipState {
                    // there has to be a better way to do this, but that paths are
                    // different, because they reside on different nodes, so we
                    // compare only the segments, which are unique per instance
                    guard let (_, otherStatus) = statusB.membershipState.first(where: { $0.key.address.path.segments == ref.address.path.segments }) else {
                        throw self.testKit(first).error("Did not get status for [\(ref)] in statusB")
                    }

                    guard otherStatus == status else {
                        throw self.testKit(first).error("Expected status \(status) for [\(ref)] in statusB, but found \(otherStatus)")
                    }
                }
            }
        }
    }

    func test_SWIMShell_shouldMonitorJoinedClusterMembers() throws {
        let local = self.setUpFirst()
        let remote = self.setUpSecond()

        local.cluster.join(node: remote.cluster.node.node)

        let localSwim: ActorRef<SWIM.Message> = try self.testKit(local)._eventuallyResolve(address: ._swim(on: local.cluster.node))
        let remoteSwim: ActorRef<SWIM.Message> = try self.testKit(remote)._eventuallyResolve(address: ._swim(on: remote.cluster.node))

        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
        try self.awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    struct ForwardedSWIMMessage {
        let message: SWIM.Message
        let recipient: ActorRef<SWIM.Message>
    }

    func forwardingSWIMBehavior(forwardTo ref: ActorRef<ForwardedSWIMMessage>) -> Behavior<SWIM.Message> {
        return .receive { context, message in
            ref.tell(.init(message: message, recipient: context.myself))
            return .same
        }
    }

    func expectPing(
        on probe: ActorTestProbe<SWIM.Message>, reply: Bool, incarnation: SWIM.Incarnation = 0,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column,
        assertPayload: (SWIM.Payload) throws -> Void = { _ in
        }
    ) throws {
        switch try probe.expectMessage(file: file, line: line, column: column) {
        case .remote(.ping(_, let replyTo, let payload)):
            try assertPayload(payload)
            if reply {
                replyTo.tell(SWIM.Ack(pinged: probe.ref, incarnation: incarnation, payload: .none))
            }
        case let message:
            throw probe.error("Expected to receive `.ping`, received \(message) instead")
        }
    }

    func expectPingRequest(
        for: ActorRef<SWIM.Message>, on probe: ActorTestProbe<SWIM.Message>,
        reply: Bool, incarnation: SWIM.Incarnation = 0,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column,
        assertPayload: (SWIM.Payload) throws -> Void = { _ in
        }
    ) throws {
        switch try probe.expectMessage(file: file, line: line, column: column) {
        case .remote(.pingReq(let toPing, _, let replyTo, let payload)):
            toPing.shouldEqual(`for`)
            try assertPayload(payload)
            if reply {
                replyTo.tell(SWIM.Ack(pinged: toPing, incarnation: incarnation, payload: .none))
            }
        case let message:
            throw probe.error("Expected to receive `.pingRequest`, received \(message) instead")
        }
    }

    func awaitStatus(
        _ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
        on swimShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try testKit.eventually(within: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(.getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()

            let otherStatus = membership.membershipState[member]
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func holdStatus(
        _ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
        on swimShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try testKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(.getMembershipState(replyTo: stateProbe.ref)))
            let otherStatus = try stateProbe.expectMessage().membershipState[member]
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>], configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var memberStatus: [ActorRef<SWIM.Message>: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return self.makeSWIM(for: address, members: memberStatus, configuredWith: configure)
    }

    func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>: SWIM.Status], configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var settings = SWIM.Settings()
        configure(&settings)
        let instance = SWIM.Instance(settings)
        for (member, status) in members {
            instance.addMember(member, status: status)
        }
        return instance
    }

    func swimBehavior(members: [ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
    }) -> Behavior<SWIM.Message> {
        return .setup { context in
            let swim = self.makeSWIM(for: context.address, members: members, configuredWith: configure)
            swim.addMyself(context.myself)
            return SWIM.Shell(swim, clusterRef: clusterRef).ready
        }
    }
}
