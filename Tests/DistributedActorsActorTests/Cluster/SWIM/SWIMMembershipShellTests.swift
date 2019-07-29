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

final class SWIMMembershipShellTests: ClusteredTwoNodesTestBase {

    func test_swim_shouldRespondWithAckToPing() throws {
        setUpLocal()
        let p = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn(swimBehavior(members: []), name: "SWIM")

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.pinged.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
    }

    func test_swim_shouldPingRandomMember() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: String.self)

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

        let ref = try local.spawn(swimBehavior(members: [remoteRefA, remoteRefB]), name: "SWIM")

        ref.tell(.local(.pingRandomMember))
        ref.tell(.local(.pingRandomMember))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_swim_shouldPingSpecificMemberWhenRequested() throws {
        setUpLocal()
        let memberProbe = localTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn(swimBehavior(members: [memberProbe.ref]), name: "SWIM")

        ref.tell(.remote(.pingReq(target: memberProbe.ref, lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .none)))

        try expectPing(on: memberProbe, reply: true)

        let response = try ackProbe.expectMessage()
        response.pinged.shouldEqual(memberProbe.ref)
        response.incarnation.shouldEqual(0)
    }

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndNoOtherNodesCanBeRequested() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let ref = try local.spawn(swimBehavior(members: [remoteProbeRef]), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkMembersAsSuspectWhenPingFailsAndRequestedNodesFailToPing() throws {
        setUpLocal()

        let probe = localTestKit.spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefA")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefB")

        let behavior = swimBehavior(members: [refA, refB]) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try local.spawn(behavior, name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw localTestKit.fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, _)) = forwardedPingReq.message else {
            throw localTestKit.fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }

        try awaitStatus(.suspect(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldNotMarkMembersAsSuspectWhenPingFailsButRequestedNodesSucceedToPing() throws {
        setUpLocal()

        let probe = localTestKit.spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefA")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIMRefB")

        let behavior = swimBehavior(members: [refA, refB]) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try local.spawn(behavior, name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw localTestKit.fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), let replyTo, _)) = forwardedPingReq.message else {
            throw localTestKit.fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
        }
        replyTo.tell(.init(pinged: suspiciousRef, incarnation: 0, payload: .none))

        try holdStatus(.alive(incarnation: 0), for: suspiciousRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspectedMembersAsAliveWhenPingingSucceedsWithinSuspicionTimeout() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let ref = try local.spawn(swimBehavior(members: [remoteProbeRef]), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: true, incarnation: 1)

        try awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_swim_shouldMarkSuspectedMembersAsDeadAfterConfiguredSuspicionTimeout() throws {
        setUpLocal()

        let p = localTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ref = try local.spawn(swimBehavior(members: [p.ref]), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: p.ref, on: ref, within: .seconds(1))

        for _ in 0 ..< SWIMSettings.default.failureDetector.suspicionTimeoutPeriodsMax {
            ref.tell(.local(.pingRandomMember))
            try expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))

        try awaitStatus(.dead, for: p.ref, on: ref, within: .seconds(1))
    }

    func test_swim_shouldSendGossipInAck() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)
        try assertAssociated(remote, with: localUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let memberProbe = remoteTestKit.spawnTestProbe(name: "RemoteSWIM", expecting: SWIM.Message.self)
        let remoteMemberRef = local._resolveKnownRemote(memberProbe.ref, onRemoteSystem: remote)

        let swimRef = try local.spawn(swimBehavior(members: [remoteMemberRef]), name: "SWIM")

        swimRef.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: remoteProbeRef, payload: .none)))

        let response: SWIM.Ack = try p.expectMessage()
        switch response.payload {
        case .membership(let members):
            members.count.shouldEqual(2)
            members.shouldContain(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0), protocolPeriod: 0))
            // the since we get this reply from the remote node, it will know "us" (swim) as a remote ref, and thus include its full address
            // so we want to expect a full (with address) ref here:
            members.shouldContain(SWIM.Member(ref: remote._resolveKnownRemote(swimRef, onRemoteSystem: local), status: .alive(incarnation: 0), protocolPeriod: 0))
        case .none:
            throw p.error("Expected gossip, but got `.none`")
        }
    }

    func test_swim_shouldSendGossipInPing_() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let behavior = swimBehavior(members: [remoteProbeRef]) { settings in
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
        setUpLocal()

        let probe = localTestKit.spawnTestProbe(expecting: ForwardedSWIMMessage.self)

        let refA = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIM-A")
        let refB = try local.spawn(forwardingSWIMBehavior(forwardTo: probe.ref), name: "SWIM-B")

        let behavior = swimBehavior(members: [refA, refB]) { settings in
            settings.failureDetector.pingTimeout = .milliseconds(50)
        }

        let swimRef = try local.spawn(behavior, name: "SWIM")

        swimRef.tell(.local(.pingRandomMember))

        let forwardedPing = try probe.expectMessage()
        guard case SWIM.Message.remote(.ping(.alive(incarnation: 0), _, _)) = forwardedPing.message else {
            throw localTestKit.fail("Expected to receive `.ping`, got [\(forwardedPing.message)]")
        }
        let suspiciousRef = forwardedPing.recipient

        let forwardedPingReq = try probe.expectMessage()
        guard case SWIM.Message.remote(.pingReq(target: suspiciousRef, lastKnownStatus: .alive(0), _, let gossip)) = forwardedPingReq.message else {
            throw localTestKit.fail("Expected to receive `.pingReq` for \(suspiciousRef), got [\(forwardedPing.message)]")
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
        setUpLocal()
        let p = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let memberProbe = localTestKit.spawnTestProbe(expecting: SWIM.Message.self)

        let ref = try local.spawn(swimBehavior(members: [memberProbe.ref]), name: "SWIM")

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
        setUpBoth()
        let membershipProbe = localTestKit.spawnTestProbe(expecting: SWIM.MembershipState.self)
        let pingProbe = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        var settings: SWIMSettings = .default
        settings.failureDetector.probeInterval = .milliseconds(50)

        let localRef = try local.spawn(SWIM.Shell(SWIM.Instance(settings)).behavior, name: "SWIM-A")
        let remoteRef = try remote.spawn(SWIM.Shell(SWIM.Instance(settings)).behavior, name: "SWIM-B")

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        remoteRef.tell(.remote(.pingReq(target: localRefRemote, lastKnownStatus: .alive(incarnation: 0), replyTo: pingProbe.ref, payload: .none)))

        try localTestKit.eventually(within: .seconds(3)) {
            localRef.tell(.local(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusA = try membershipProbe.expectMessage()

            remoteRef.tell(.local(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusB = try membershipProbe.expectMessage()

            guard statusA.membershipStatus.count == 2, statusB.membershipStatus.count == 2 else {
                throw localTestKit.error("Expected count of both members to be 2, was [statusA=\(statusA.membershipStatus.count), statusB=\(statusB.membershipStatus.count)]")
            }

            for (ref, status) in statusA.membershipStatus {
                // there has to be a better way to do this, but that paths are
                // different, because they reside on different nodes, so we
                // compare only the segments, which are unique per instance
                guard let (_, otherStatus) = statusB.membershipStatus.first(where: { $0.key.address.path.segments == ref.address.path.segments }) else {
                    throw localTestKit.error("Did not get status for [\(ref)] in statusB")
                }

                guard otherStatus == status else {
                    throw localTestKit.error("Expected status \(status) for [\(ref)] in statusB, but found \(otherStatus)")
                }
            }
        }
    }

    func test_SWIMMembershipShell_shouldBeAbleToJoinACluster() throws {
        setUpBoth()

        let remoteSwim = try remote._spawnSystemActor(SWIMMembershipShell(settings: .default).behavior, name: SWIMMembershipShell.name, perpetual: true)
        let localSwim = try local._spawnSystemActor(SWIMMembershipShell(settings: .default).behavior, name: SWIMMembershipShell.name, perpetual: true)

        localSwim.tell(.local(.join(remoteUniqueAddress.address)))

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
        let stateProbe = localTestKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try localTestKit.eventually(within: timeout, file: file, line: line, column: column) {
            membershipShell.tell(.local(.getMembershipState(replyTo: stateProbe.ref)))
            let membership = try stateProbe.expectMessage()
            pinfo("membership: \(membership.membershipStatus)")
            let otherStatus = membership.membershipStatus[member]
            guard otherStatus == status else {
                throw localTestKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
            }
        }
    }

    func holdStatus(_ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
                    on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
                    file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let stateProbe = localTestKit.spawnTestProbe(expecting: SWIM.MembershipState.self)

        try localTestKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            membershipShell.tell(.local(.getMembershipState(replyTo: stateProbe.ref)))
            let otherStatus = try stateProbe.expectMessage().membershipStatus[member]
            guard otherStatus == status else {
                throw localTestKit.error("Expected status [\(status)] for [\(member)], but found \(otherStatus.debugDescription)")
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

    func swimBehavior(members: [ActorRef<SWIM.Message>], configuredWith configure: @escaping (inout SWIM.Settings) -> Void = { _ in }) -> Behavior<SWIM.Message> {
        return .setup { context in
            let swim = self.makeSWIM(for: context.address, members: members, configuredWith: configure)
            swim.addMyself(context.myself)
            return SWIM.Shell(swim).ready
        }
    }
}
