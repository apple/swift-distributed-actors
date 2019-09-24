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

final class SWIMShellTests: ClusteredNodesTestBase {
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

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndNoOtherNodesCanBeRequested() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)

        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndRequestedNodesFailToPing() throws {
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

        try self.awaitStatus(.suspect(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotMarkMembersAsSuspectWhenPingFailsButRequestedNodesSucceedToPing() throws {
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

    func test_swim_shouldMarkSuspectedMembersAsAliveWhenPingingSucceedsWithinSuspicionTimeout() throws {
        let first = self.setUpFirst()
        let second = self.setUpSecond()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.cluster.node)

        let p = self.testKit(second).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = first._resolveKnownRemote(p.ref, onRemoteSystem: second)
        let ref = try first.spawn("SWIM", self.swimBehavior(members: [remoteProbeRef], clusterRef: self.firstClusterProbe.ref))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: false)

        try self.awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))

        ref.tell(.local(.pingRandomMember))

        try self.expectPing(on: p, reply: true, incarnation: 1)

        try self.awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotifyClusterAboutUnreachableNodeAfterConfiguredSuspicionTimeoutAndMarkDeadWhenConfirmed() throws {
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

        try self.awaitStatus(.suspect(incarnation: 0), for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMax {
            ref.tell(.local(.pingRandomMember))
            try self.expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))

        let message = try firstClusterProbe.expectMessage()
        guard case .command(.reachabilityChanged(let address, .unreachable)) = message else {
            throw self.testKit(first).fail("expected to receive `.command(.markUnreachable)`, but got `\(message)`")
        }
        try self.holdStatus(.unreachable(incarnation: 0), for: remoteMemberRef, on: ref, within: .milliseconds(200))

        ref.tell(.local(.confirmDead(address)))
        try self.awaitStatus(.dead, for: remoteMemberRef, on: ref, within: .seconds(1))
    }

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

    func test_swim_shouldSendGossipInPing_() throws {
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

            defer {
                self.printCapturedLogs(first)
                self.printCapturedLogs(second)
            }

            let membershipProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.MembershipState.self)
            let pingProbe = self.testKit(first).spawnTestProbe(expecting: SWIM.Ack.self)

            var settings: SWIMSettings = .default
            settings.failureDetector.probeInterval = .milliseconds(100)

            var firstSwim: ActorRef<SWIM.Message> = first._resolve(context: ResolveContext<SWIM.Message>(address: ActorAddress._swim(on: first.cluster.node), system: first))
            var secondSwim: ActorRef<SWIM.Message> = second._resolve(context: ResolveContext<SWIM.Message>(address: ActorAddress._swim(on: second.cluster.node), system: second))

            while firstSwim.path.starts(with: ._dead) || secondSwim.path.starts(with: ._dead) {
                pprint("Resolved a dead SWIM... trying again")
                firstSwim = first._resolve(context: ResolveContext<SWIM.Message>(address: ActorAddress._swim(on: first.cluster.node), system: first))
                secondSwim = second._resolve(context: ResolveContext<SWIM.Message>(address: ActorAddress._swim(on: second.cluster.node), system: second))
            }

            let localRefRemote = second._resolveKnownRemote(firstSwim, onRemoteSystem: first)

            secondSwim.tell(.remote(.pingReq(target: localRefRemote, lastKnownStatus: .alive(incarnation: 0), replyTo: pingProbe.ref, payload: .none)))

            try self.testKit(first).eventually(within: .seconds(10)) {
                firstSwim.tell(.testing(.getMembershipState(replyTo: membershipProbe.ref)))
                let statusA = try membershipProbe.expectMessage(within: .seconds(1))

                secondSwim.tell(.testing(.getMembershipState(replyTo: membershipProbe.ref)))
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

        let swimPath = try ActorPath._system.appending(SWIMShell.name)
        let swimAddress = ActorAddress(path: swimPath, incarnation: ActorIncarnation.perpetual)

        let remoteSwim: ActorRef<SWIM.Message> = remote._resolve(context: .init(address: swimAddress, system: remote))
        let localSwim: ActorRef<SWIM.Message> = local._resolve(context: .init(address: swimAddress, system: local))

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
        assertPayload: (SWIM.Payload) throws -> Void = { _ in }
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
        assertPayload: (SWIM.Payload) throws -> Void = { _ in }
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
        on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try testKit.eventually(within: timeout, file: file, line: line, column: column) {
            membershipShell.tell(.testing(.getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()

            let otherStatus = membership.membershipState[member]
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func holdStatus(
        _ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
        on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let testKit = self._testKits.first!
        let stateProbe = testKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try testKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            membershipShell.tell(.testing(.getMembershipState(replyTo: stateProbe.ref)))
            let otherStatus = try stateProbe.expectMessage().membershipState[member]
            guard otherStatus == status else {
                throw testKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>], configuredWith configure: (inout SWIM.Settings) -> Void = { _ in }) -> SWIM.Instance {
        var memberStatus: [ActorRef<SWIM.Message>: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return self.makeSWIM(for: address, members: memberStatus, configuredWith: configure)
    }

    func makeSWIM(for address: ActorAddress, members: [ActorRef<SWIM.Message>: SWIM.Status], configuredWith configure: (inout SWIM.Settings) -> Void = { _ in }) -> SWIM.Instance {
        var settings = SWIM.Settings()
        configure(&settings)
        let instance = SWIM.Instance(settings)
        for (member, status) in members {
            instance.addMember(member, status: status)
        }
        return instance
    }

    func swimBehavior(members: [ActorRef<SWIM.Message>], clusterRef: ClusterShell.Ref, configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in }) -> Behavior<SWIM.Message> {
        return .setup { context in
            let swim = self.makeSWIM(for: context.address, members: members, configuredWith: configure)
            swim.addMyself(context.myself)
            return SWIM.Shell(swim, clusterRef: clusterRef).ready
        }
    }
}
