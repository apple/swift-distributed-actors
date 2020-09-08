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
@testable import SWIM
import XCTest

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

    func test_swim_shouldNotIncreaseProbeInterval_whenLowMultiplier() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let ref = try first.spawn(
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

    func test_swim_shouldRespondWithAckToPing() throws {
        let first = self.setUpFirst()
        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [], clusterRef: self.firstClusterProbe.ref))

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

    func test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)

        let dummyProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let firstPeerProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.PingOriginRef.Message.self)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [firstPeerProbe.ref], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.remote(.pingRequest(target: dummyProbe.ref, pingRequestOrigin: ackProbe.ref, payload: .none, sequenceNumber: 13)))

        try self.expectPing(on: dummyProbe, reply: false)
        let response = try ackProbe.expectMessage()
        guard case .remote(.pingResponse(.nack)) = response else {
            throw self.testKit(first).error("expected nack, but got \(response)")
        }
    }

    func test_swim_shouldPingRandomMember() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()
        let third = self.setUpNode("third")

        first.cluster.join(node: second.cluster.uniqueNode.node)
        third.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let p = self.testKit(second).spawnTestProbe(expecting: String.self)

        func behavior(postFix: String) -> Behavior<SWIM.Message> {
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

        let refA = try second.spawn("SWIM-A", behavior(postFix: "A"))
        let refB = try third.spawn("SWIM-B", behavior(postFix: "B"))
        let ref = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.protocolPeriodTick))
        ref.tell(.local(.protocolPeriodTick))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() throws {
        let first = self.setUpFirst()
        let second = self.setUpFirst()

        let secondProbe = self.testKit(second).spawnTestProbe("SWIM-2", expecting: SWIM.Message.self)
        let ackProbe = self.testKit(second).spawnTestProbe(expecting: SWIM.PingOriginRef.Message.self)

        let ref = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [secondProbe.ref], clusterRef: self.firstClusterProbe.ref))
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

    func test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let firstSwim = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [probeOnSecond.ref], clusterRef: self.firstClusterProbe.ref))
        firstSwim.tell(.local(.protocolPeriodTick))

        try self.expectPing(on: probeOnSecond, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstSwim.node]), for: probeOnSecond.ref, on: firstSwim, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing() throws {
        let systemSWIM = self.setUpFirst()
        let systemA = self.setUpNode("A")
        let systemB = self.setUpNode("B")

        let probeA = self.testKit(systemA).spawnTestProbe(expecting: ForwardedSWIMMessage.self)
        let refA = try systemA.spawn("SWIM-A", self.forwardingSWIMBehavior(forwardTo: probeA.ref))
        let probeB = self.testKit(systemB).spawnTestProbe(expecting: ForwardedSWIMMessage.self)
        let refB = try systemB.spawn("SWIM-B", self.forwardingSWIMBehavior(forwardTo: probeB.ref))

        let swim = try systemSWIM.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [refA, refB], clusterRef: self.firstClusterProbe.ref) { settings in
            settings.pingTimeout = .milliseconds(50)
        })
        swim.tell(.local(.protocolPeriodTick))

        // eventually it will ping/pingRequest and as none of the swims reply it should mark as suspect
        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [swim.node]), for: refA, on: swim, within: .seconds(3))
    }

//    func test_swim_shouldNotifyClusterAboutUnreachableNode_afterConfiguredSuspicionTimeout_andMarkDeadWhenConfirmed() throws {
//        let first = self.setUpFirst()
//        let firstNode = first.cluster.uniqueNode
//        let second = self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
//        let remoteMemberRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
//        let timeSource = TestTimeSource()
//        let suspicionTimeoutPeriodsMax = 1000
//        let suspicionTimeoutPeriodsMin = 1
//
//        let ref = try first.spawn(
//            "SWIM",
//            SWIMActorShell.swimTestBehavior(members: [remoteMemberRef], clusterRef: self.firstClusterProbe.ref) { settings in
//                settings.timeSourceNow = timeSource.now
//                settings.lifeguard.suspicionTimeoutMin = .nanoseconds(suspicionTimeoutPeriodsMin)
//                settings.lifeguard.suspicionTimeoutMax = .nanoseconds(suspicionTimeoutPeriodsMax)
//            }
//        )
//
//        ref.tell(.local(.protocolPeriodTick))
//        try self.expectPing(on: p, reply: false)
//        timeSource.tick()
//
//        try self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [firstNode]), for: remoteMemberRef, on: ref, within: .seconds(1))
//
//        for _ in 0 ..< suspicionTimeoutPeriodsMax {
//            ref.tell(.local(.protocolPeriodTick))
//            try self.expectPing(on: p, reply: false)
//            timeSource.tick()
//        }
//
//        // We need to trigger an additional ping to advance the protocol period
//        // and have the SWIM actor mark the remote node as dead
//        ref.tell(.local(.protocolPeriodTick))
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
    func test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached() throws {
        let first = self.setUpFirst()
        let firstNode = first.cluster.uniqueNode
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = first._resolveKnownRemote(probeOnSecond.ref, onRemoteSystem: second)
        let maxIndependentSuspicions = 10
        let suspicionTimeoutPeriodsMax = 1000
        let suspicionTimeoutPeriodsMin = 1
        let timeSource = TestTimeSource()

        let ref = try first.spawn(
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
        let ackProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Message.self)
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

    private func expectReachabilityInSnapshot(_ testKit: ActorTestKit, node: UniqueNode, expect expected: Cluster.MemberReachability) throws {
        try testKit.eventually(within: .seconds(3)) {
            let p11 = testKit.spawnEventStreamTestProbe(subscribedTo: testKit.system.cluster.events)
            guard case .some(Cluster.Event.snapshot(let snapshot)) = try p11.maybeExpectMessage() else {
                throw testKit.error("Expected snapshot, was: \(String(reflecting: p11.lastMessage))")
            }

            if let secondMember = snapshot.uniqueMember(node) {
                if secondMember.reachability == expected {
                    return
                } else {
                    throw testKit.error("Expected \(node) on \(testKit.system.cluster.uniqueNode) to be [\(expected)] but was: \(secondMember)")
                }
            } else {
                pinfo("Unable to assert reachability of \(node) on \(testKit.system.cluster.uniqueNode) since membership did not contain it. Was: \(snapshot)")
                () // it may have technically been removed already, so this is "fine"
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Gossiping

    func test_swim_shouldSendGossipInAck() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let secondSwimProbe = self.testKit(second).spawnTestProbe("RemoteSWIM", expecting: SWIM.Message.self)

        let swimRef = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [secondSwimProbe.ref], clusterRef: self.firstClusterProbe.ref))
        swimRef.tell(.remote(.ping(pingOrigin: probeOnSecond.ref, payload: .none, sequenceNumber: 1)))

        let response = try probeOnSecond.expectMessage()
        switch response {
        case .remote(.pingResponse(.ack(_, _, .membership(let members), _))):
            members.count.shouldEqual(2)
            members.shouldContain(SWIM.Member(peer: secondSwimProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full address
            // so we want to expect a full (with node) ref here:
            members.shouldContain(SWIM.Member(peer: swimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
        case let reply:
            throw probeOnSecond.error("Expected gossip with membership, but got \(reply)")
        }
    }

//
//    func test_swim_shouldIncrementIncarnation_whenProcessSuspicionAboutSelf() throws {
//        let first = self.setUpFirst()
//        let p = self.testKit(first).spawnTestProbe(expecting: SWIM.PingResponse.self)
//
//        let firstSwim = try first.spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [], clusterRef: self.firstClusterProbe.ref))
//
//        firstSwim.tell(.remote(..ping(pingOrigin: p.ref, payload: .membership([SWIM.Member(ref: firstSwim, status: .suspect(incarnation: 0, suspectedBy: [first.cluster.uniqueNode.asSWIMNode]), protocolPeriod: 0)]))))
//
//        let response = try p.expectMessage()
//
//        switch response {
//        case .ack(_, let incarnation, .membership(let members), _):
//            members.shouldContain(SWIM.Member(peer: firstSwim, status: .alive(incarnation: 1), protocolPeriod: 0))
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
//        var settings = SWIM.Settings()
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
//                guard let (_, otherStatus) = statusB.membershipState.first(where: { $0.key.address.path.segments == firstSwim.address.path.segments }) else {
//                    throw self.testKit(first).error("Did not get status for [\(firstSwim)] in statusB")
//                }
//
//                guard otherStatus == status else {
//                    throw self.testKit(first).error("Expected status \(status) for [\(firstSwim)] in statusB, but found \(otherStatus)")
//                }
//            }
//        }
//    }

    func test_SWIMShell_shouldMonitorJoinedClusterMembers() throws {
        let local = self.setUpFirst()
        let remote = self.setUpSecond()

        local.cluster.join(node: remote.cluster.uniqueNode.node)

        let localSwim: ActorRef<SWIM.Message> = try self.testKit(local)._eventuallyResolve(address: ._swim(on: local.cluster.uniqueNode))
        let remoteSwim: ActorRef<SWIM.Message> = try self.testKit(remote)._eventuallyResolve(address: ._swim(on: remote.cluster.uniqueNode))

        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
        try self.awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
    }

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
                replyTo.tell(.remote(.pingResponse(.ack(target: probe.ref, incarnation: incarnation, payload: .none, sequenceNumber: sequenceNumber))))
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
        let stateProbe = testKit.spawnTestProbe(expecting: [SWIM.Member].self)

        try testKit.eventually(within: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(._getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()

            let otherStatus = membership
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map { $0.status }
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription); Membership: \(membership)", file: file, line: line)
            }
        }
    }

    func holdStatus(
        _ status: SWIM.Status, for peer: ActorRef<SWIM.Message>,
        on swimShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: [SWIM.Member].self)

        try testKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            swimShell.tell(._testing(._getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()
            let otherStatus = membership
                .first(where: { $0.peer as! SWIM.Ref == peer })
                .map { $0.status }
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(peer)], but found \(otherStatus.debugDescription)")
            }
        }
    }
}

extension SWIMActorShell {
    private static func makeSWIM(for address: ActorAddress, members: [SWIM.Ref], context: ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var memberStatus: [SWIM.Ref: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return self.makeSWIM(for: address, members: memberStatus, context: context, configuredWith: configure)
    }

    private static func makeSWIM(for address: ActorAddress, members: [SWIM.Ref: SWIM.Status], context: ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
    }) -> SWIM.Instance {
        var settings = context.system.settings.cluster.swim
        configure(&settings)
        let instance = SWIM.Instance(settings: settings, myself: context.myself)
        for (member, status) in members {
            _ = instance.addMember(member, status: status)
        }
        return instance
    }

    static func swimTestBehavior(members: [ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
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
    var currentTime: Atomic<UInt64>

    /// starting from 1 to ensure .distantPast is already expired
    init(currentTime: UInt64 = 1) {
        self.currentTime = Atomic(value: currentTime)
    }

    func now() -> DispatchTime {
        DispatchTime(uptimeNanoseconds: self.currentTime.load())
    }

    func tick() {
        _ = self.currentTime.add(100)
    }
}
