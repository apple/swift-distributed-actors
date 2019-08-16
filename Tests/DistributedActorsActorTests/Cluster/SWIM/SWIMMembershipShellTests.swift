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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class SWIMMembershipShellTests: ClusteredNodesTestBase {

    var localClusterProbe: ActorTestProbe<ClusterShell.Message>!
    var remoteClusterProbe: ActorTestProbe<ClusterShell.Message>!

    func setUpLocal(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let local = super.setUpNode("local", modifySettings)
        self.localClusterProbe = self.testKit(local).spawnTestProbe()
        return local
    }

    func setUpRemote(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let remote = super.setUpNode("remote", modifySettings)
        self.remoteClusterProbe = self.testKit(remote).spawnTestProbe()
        return remote
    }

    func test_swim_shouldRespondWithAckToPing() throws {
        let local = setUpLocal()
        let p = self.testKit(local).spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn(swimBehavior(members: [], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.pinged.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
    }

    func test_swim_shouldPingRandomMember() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: String.self)

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

        let refA = try remote.spawn(behavior(postFix: "A"), name: "SWIM-A")
        let remoteRefA = local._resolveKnownRemote(refA, onRemoteSystem: remote)
        let refB = try remote.spawn(behavior(postFix: "B"), name: "SWIM-B")
        let remoteRefB = local._resolveKnownRemote(refB, onRemoteSystem: remote)

        let ref = try local.spawn(swimBehavior(members: [remoteRefA, remoteRefB], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.local(.pingRandomMember))
        ref.tell(.local(.pingRandomMember))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() throws {
        let local = setUpLocal()

        let memberProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn(swimBehavior(members: [memberProbe.ref], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.remote(.pingReq(target: memberProbe.ref, lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .none)))

        try expectPing(on: memberProbe, reply: true)

        let response = try ackProbe.expectMessage()
        response.pinged.shouldEqual(memberProbe.ref)
        response.incarnation.shouldEqual(0)
    }

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndNoOtherNodesCanBeRequested() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let ref = try local.spawn(swimBehavior(members: [remoteProbeRef], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndRequestedNodesFailToPing() throws {
        let local = setUpLocal()

        let probe = self.testKit(local).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefA")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefB")

        let behavior = swimBehavior(members: [refA, refB], clusterRef: localClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try local.spawn(behavior, name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(local).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, _)) = forwardedPingReq.message else {
            throw self.testKit(local).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }

        try awaitStatus(.suspect(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotMarkMembersAsSuspectWhenPingFailsButRequestedNodesSucceedToPing() throws {
        let local = setUpLocal()

        let probe = self.testKit(local).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefA")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefB")

        let behavior = swimBehavior(members: [refA, refB], clusterRef: localClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try local.spawn(behavior, name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(local).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), let replyTo, _)) = forwardedPingReq.message else {
            throw self.testKit(local).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }
        replyTo.tell(.init(pinged: suspiciousRef, incarnation: 0, payload: .none))

        try holdStatus(.alive(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspectedMembersAsAliveWhenPingingSucceedsWithinSuspicionTimeout() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let ref = try local.spawn(swimBehavior(members: [remoteProbeRef], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: true, incarnation: 1)

        try awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotifyClusterAboutUnreachableNodeAfterConfiguredSuspicionTimeoutAndMarkDeadWhenConfirmed() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let ref = try local.spawn(swimBehavior(members: [remoteMemberRef], clusterRef: localClusterProbe.ref), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteMemberRef, on: ref, within: .seconds(1))

        for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMax {
            ref.tell(.local(.pingRandomMember))
            try expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))

        let message = try localClusterProbe.expectMessage()
        guard case .command(.reachabilityChanged(let address, .unreachable)) = message else {
            throw self.testKit(local).fail("expected to receive `.command(.markUnreachable)`, but got `\(message)`")
        }
        try holdStatus(.unreachable(incarnation: 0), for: remoteMemberRef, on: ref, within: .milliseconds(200))

        ref.tell(.local(.confirmDead(address)))
        try awaitStatus(.dead, for: remoteMemberRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldSendGossipInAck() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: SWIM.Ack.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let memberProbe = self.testKit(remote).spawnTestProbe(name: "RemoteSWIM", expecting: SWIM.Message.self)
        let remoteMemberRef = local._resolveKnownRemote(memberProbe.ref, onRemoteSystem: remote)

        let swimRef = try local.spawn(swimBehavior(members: [remoteMemberRef], clusterRef: localClusterProbe.ref), name: "SWIM")

        swimRef.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: remoteProbeRef, payload: .none)))

        let response: SWIM.Ack = try p.expectMessage()
        switch response.payload {
        case .membership(let members):
            members.count.shouldEqual(2)
            members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full address
            // so we want to expect a full (with node) ref here:
            members.shouldContain(SWIM.Member(ref: remote._resolveKnownRemote(swimRef, onRemoteSystem: local), status: .alive(incarnation: 0), protocolPeriod: 0))
        case .none:
            throw p.error("Expected gossip, but got `.none`")
        }
    }

    func test_swim_shouldSendGossipInPing_() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)

        let p = self.testKit(remote).spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let behavior = swimBehavior(members: [remoteProbeRef], clusterRef: localClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let swimRef = try local.spawn(behavior, name: "SWIM")
        let remoteSwimRef = remote._resolveKnownRemote(swimRef, onRemoteSystem: local)

        swimRef.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false) {
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
        let local = setUpLocal()

        let probe = self.testKit(local).spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIM-A")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIM-B")

        let behavior = swimBehavior(members: [refA, refB], clusterRef: localClusterProbe.ref) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let swimRef = try local.spawn(behavior, name: "SWIM")

        swimRef.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw self.testKit(local).fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, let gossip)) = forwardedPingReq.message else {
            throw self.testKit(local).fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
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
        let local = setUpLocal()
        let p = self.testKit(local).spawnTestProbe(expecting: SWIM.Ack.self)
        let memberProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Message.self)

        let ref = try local.spawn(swimBehavior(members: [memberProbe.ref], clusterRef: localClusterProbe.ref), name: "SWIM")

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
        let local = setUpLocal()
        let remote = setUpRemote()

        let membershipProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.MembershipState.self)
        let pingProbe = self.testKit(local).spawnTestProbe(expecting: SWIM.Ack.self)

        var settings: SWIMSettings = .default
        settings.failureDetector.probeInterval = .milliseconds(50)

        let localRef = try local.spawn(SWIM.Shell(SWIM.Instance(settings), clusterRef: localClusterProbe.ref).behavior, name: "SWIM-A")
        let remoteRef = try remote.spawn(SWIM.Shell(SWIM.Instance(settings), clusterRef: remoteClusterProbe.ref).behavior, name: "SWIM-B")

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        remoteRef.tell(.remote(.pingReq(target: localRefRemote, lastKnownStatus: .alive(incarnation: 0), replyTo: pingProbe.ref, payload: .none)))

        try self.testKit(local).eventually(within: .seconds(3)) {
            localRef.tell(.testing(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusA = try membershipProbe.expectMessage()

            remoteRef.tell(.testing(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusB = try membershipProbe.expectMessage()

            guard statusA.membershipState.count == 2, statusB.membershipState.count == 2 else {
                throw self.testKit(local).error("Expected count of both members to be 2, was [statusA=\(statusA.membershipState.count), statusB=\(statusB.membershipState.count)]")
            }

            for (ref, status) in statusA.membershipState {
                // there has to be a better way to do this, but that paths are
                // different, because they reside on different nodes, so we
                // compare only the segments, which are unique per instance
                guard let (_, otherStatus) = statusB.membershipState.first(where: { $0.key.address.path.segments == ref.address.path.segments }) else {
                    throw self.testKit(local).error("Did not get status for [\(ref)] in statusB")
                }

                guard otherStatus == status else {
                    throw self.testKit(local).error("Expected status \(status) for [\(ref)] in statusB, but found \(otherStatus)")
                }
            }
        }
    }

    func test_SWIMMembershipShell_shouldBeAbleToJoinACluster() throws {
        let local = setUpLocal()
        let remote = setUpRemote()

        let swimPath = try ActorPath._system.appending(SWIMShell.name)
        let swimAddress = ActorAddress(path: swimPath, incarnation: ActorIncarnation.perpetual)

        let remoteSwim: ActorRef<SWIM.Message> = remote._resolve(context: .init(address: swimAddress, system: remote))
        let localSwim: ActorRef<SWIM.Message> = local._resolve(context: .init(address: swimAddress, system: local))

        localSwim.tell(.local(.monitor(remote.cluster.node.node)))

        let remoteSwimRef = local._resolveKnownRemote(remoteSwim, onRemoteSystem: remote)
        try awaitStatus(.alive(incarnation: 0), for: remoteSwimRef, on: localSwim, within: .seconds(1))
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

    func expectPing(on probe: ActorTestProbe<SWIM.Message>, reply: Bool, incarnation: SWIM.Incarnation = 0,
                    file: StaticString = #file, line: UInt = #line, column: UInt = #column,
                    assertPayload: (SWIM.Payload) throws -> Void = { _ in }) throws {
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

    func expectPingRequest(for: ActorRef<SWIM.Message>, on probe: ActorTestProbe<SWIM.Message>,
                           reply: Bool, incarnation: SWIM.Incarnation = 0,
                           file: StaticString = #file, line: UInt = #line, column: UInt = #column,
                           assertPayload: (SWIM.Payload) throws -> Void = { _ in }) throws {
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

    func awaitStatus(_ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
                     on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
                     file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
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

    func holdStatus(_ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
                    on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
                    file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
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
