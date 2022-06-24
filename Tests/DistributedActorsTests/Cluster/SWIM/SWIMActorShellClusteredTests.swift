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

        // Down the node so it doesn't respond to ping request
        thirdNode.shutdown()
        try await self.ensureNodes(.removed, on: secondNode, nodes: thirdNode.cluster.uniqueNode)

        let originPeer = try SWIMActorShell.resolve(id: first.id._asRemote, using: secondNode)
        let targetPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: secondNode)
        // `first` sends ping request to `third` through `second`
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

        // SWIMActorShell's sendFirstRemotePing might have been triggered when we associate
        // the nodes, reset so we get metrics just for our handlePeriodicProtocolPeriodTick calls.
        (try await self.metrics.getSWIMCounter(second) { $0.messageInboundCount })?.reset()
        (try await self.metrics.getSWIMCounter(third) { $0.messageInboundCount })?.reset()

        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
            __secretlyKnownToBeLocal.handlePeriodicProtocolPeriodTick()
        }

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
        // `first` sends ping request to `third` through `second`
        let response = try await second.pingRequest(target: targetPeer, pingRequestOrigin: originPeer, payload: .none, sequenceNumber: 13)

        guard case .ack(let pinged, let incarnation, _, _) = response else {
            throw testKit(firstNode).fail("Expected ack, but got \(response)")
        }

        (pinged as! SWIMActorShell).id.shouldEqual(third.id)
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

        let targetPeer = try SWIMActorShell.resolve(id: second.id._asRemote, using: firstNode)
        let throughPeer = try SWIMActorShell.resolve(id: third.id._asRemote, using: firstNode)

        // Fake a failed ping and ping request
        _ = await first.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
            _ = __secretlyKnownToBeLocal.handlePingResponse(
                response: .timeout(target: targetPeer, pingRequestOrigin: nil, timeout: .milliseconds(100), sequenceNumber: 13),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil
            )

            __secretlyKnownToBeLocal.handlePingRequestResponse(
                response: .timeout(target: targetPeer, pingRequestOrigin: first, timeout: .milliseconds(100), sequenceNumber: 5),
                pinged: throughPeer
            )
        }

        // eventually it will ping/pingRequest and as all the pings (supposedly) time out it should mark as suspect
        try await self.awaitStatus(.suspect(incarnation: 0, suspectedBy: [first.node]), for: targetPeer, on: first, within: .seconds(1))
    }

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

//        let first = await self.setUpFirst()
//        let second = await self.setUpSecond()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
//        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
//
//        let probeOnSecond = self.testKit(second).makeTestProbe(expecting: SWIM.Message.self)
//        let secondSwimProbe = self.testKit(second).makeTestProbe("RemoteSWIM", expecting: SWIM.Message.self)
//
//        let swimRef = try first._spawn("SWIM", SWIMActorShell.swimTestBehavior(members: [secondSwimProbe.ref], clusterRef: self.firstClusterProbe.ref))
//        swimRef.tell(.remote(.ping(pingOrigin: probeOnSecond.ref, payload: .none, sequenceNumber: 1)))
//
//        let response = try probeOnSecond.expectMessage()
//        switch response {
//        case .remote(.pingResponse(.ack(_, _, .membership(let members), _))):
//            members.count.shouldEqual(2)
//            members.shouldContain(SWIM.Member(peer: secondSwimProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
//            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full id
//            // so we want to expect a full (with node) ref here:
//            members.shouldContain(SWIM.Member(peer: swimRef, status: .alive(incarnation: 0), protocolPeriod: 0))
//        case let reply:
//            throw probeOnSecond.error("Expected gossip with membership, but got \(reply)")
//        }
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

//        let localSwim: _ActorRef<SWIM.Message> = try self.testKit(local)._eventuallyResolve(id: ._swim(on: local.cluster.uniqueNode))
//        let remoteSwim: _ActorRef<SWIM.Message> = try self.testKit(remote)._eventuallyResolve(id: ._swim(on: remote.cluster.uniqueNode))
//
//        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
//        try self.awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
    }

    /*
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
         _ status: SWIM.Status, for peer: _ActorRef<SWIM.Message>,
         on swimShell: _ActorRef<SWIM.Message>, within timeout: Duration,
         file: StaticString = #file, line: UInt = #line, column: UInt = #column
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
         file: StaticString = #file, line: UInt = #line, column: UInt = #column
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
      */

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

// extension SWIMActorShell {
//    func addMembers(_ members: [SWIM.Shell]) {
//        var memberStatus: [SWIM.Shell: SWIM.Status] = [:]
//        for member in members {
//            memberStatus[member] = .alive(incarnation: 0)
//        }
//        self.addMembers(memberStatus)
//    }
//
//    func addMembers(_ members: [SWIM.Shell: SWIM.Status]) {
//        for (member, status) in members {
//            _ = self.swim.addMember(member, status: status)
//        }
//    }

//    private static func makeSWIM(for id: ActorID, members: [SWIM.Ref], context: _ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
//    }) -> SWIM.Instance {
//        var memberStatus: [SWIM.Ref: SWIM.Status] = [:]
//        for member in members {
//            memberStatus[member] = .alive(incarnation: 0)
//        }
//        return self.makeSWIM(for: id, members: memberStatus, context: context, configuredWith: configure)
//    }
//
//    private static func makeSWIM(for id: ActorID, members: [SWIM.Ref: SWIM.Status], context: _ActorContext<SWIM.Message>, configuredWith configure: (inout SWIM.Settings) -> Void = { _ in
//    }) -> SWIM.Instance {
//        var settings = context.system.settings.swim
//        configure(&settings)
//        let instance = SWIM.Instance(settings: settings, myself: context.myself)
//        for (member, status) in members {
//            _ = instance.addMember(member, status: status)
//        }
//        return instance
//    }

//    static func swimTestBehavior(members: [_ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
//    }) -> _Behavior<SWIM.Message> {
//        .setup { context in
//            let swim = self.makeSWIM(for: context.id, members: members, context: context, configuredWith: configure)
//            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
//        }
//    }
//
//    static func swimBehavior(members: [_ActorRef<SWIM.Message>: SWIM.Status], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in
//    }) -> _Behavior<SWIM.Message> {
//        .setup { context in
//            let swim = self.makeSWIM(for: context.id, members: members, context: context, configuredWith: configure)
//            return SWIM.Shell.ready(shell: SWIMActorShell(swim, clusterRef: clusterRef))
//        }
//    }
// }

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
