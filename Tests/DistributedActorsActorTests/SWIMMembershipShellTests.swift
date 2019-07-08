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

class SWIMMembershipShellTests: ClusteredTwoNodesTestBase {
    func test_SWIMMembershipShell_shouldRespondWithAckToPing() throws {
        setUpLocal()
        let p = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        let ref = try local.spawn(SWIMMembershipShell.ready(state: makeSwimState(members: [])), name: "SWIM")

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.from.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
    }

    func test_SWIMMembershipShell_shouldPingRandomMember() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: String.self)

        func behavior(postFix: String) -> Behavior<SWIM.Message> {
            return .receive { context, message in
                switch message {
                case .remote(.ping(_, let replyTo, _)):
                    replyTo.tell(.init(from: context.myself, incarnation: 0, payload: .none))
                    p.tell("pinged:\(postFix)")
                default: ()
                }

                return .same
            }
        }

        let refA = try remote.spawn(behavior(postFix: "A"), name: "RefA")
        let remoteRefA = local._resolveKnownRemote(refA, onRemoteSystem: remote)
        let refB = try remote.spawn(behavior(postFix: "B"), name: "RefB")
        let remoteRefB = local._resolveKnownRemote(refB, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteRefA, remoteRefB])
        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))
        ref.tell(.local(.pingRandomMember))

        try p.expectMessagesInAnyOrder(["pinged:A", "pinged:B"], within: .seconds(2))
    }

    func test_SWIMMembershipShell_shouldPingSpecificMemberWhenRequested() throws {
        setUpLocal()
        let memberProbe = localTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let ackProbe = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [memberProbe.ref])
        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.remote(.pingReq(target: memberProbe.ref, lastKnownStatus: .alive(incarnation: 0), replyTo: ackProbe.ref, payload: .none)))

        try expectPing(on: memberProbe, reply: true)

        let response = try ackProbe.expectMessage()
        response.from.shouldEqual(memberProbe.ref)
        response.incarnation.shouldEqual(0)
    }

    func test_SWIMMembershipShell_shouldMarkMembersAsSuspectWhenPingFailsAndNoOtherNodesCanBeRequested() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRef])
        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_SWIMMembershipShell_shouldMarkMembersAsSuspectWhenPingFailsAndRequestedNodesFailToPing() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let probeA = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefA = local._resolveKnownRemote(probeA.ref, onRemoteSystem: remote)
        let probeB = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefB = local._resolveKnownRemote(probeB.ref, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRefA, remoteProbeRefB]) {
            $0.failureDetector.pingTimeout = .milliseconds(50)
        }

        let pingProbe: ActorTestProbe<SWIM.Message>
        let suspiciousProbe: ActorTestProbe<SWIM.Message>
        let suspiciousRemoteRef: ActorRef<SWIM.Message>
        // we take out the one member, to guarantee that the other one will be pinged, so we
        // can be sure to act on the correct reference, which otherwise would not be possible,
        // because of the randomness
        if swimState.nextMemberToPing()! == remoteProbeRefA {
            pingProbe = probeA
            suspiciousProbe = probeB
            suspiciousRemoteRef = remoteProbeRefB
        } else {
            pingProbe = probeB
            suspiciousProbe = probeA
            suspiciousRemoteRef = remoteProbeRefA
        }

        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: suspiciousProbe, reply: false)

        try expectPingRequest(for: suspiciousProbe.ref, on: pingProbe, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: suspiciousRemoteRef, on: ref, within: .seconds(1))
    }

    func test_SWIMMembershipShell_shouldNotMarkMembersAsSuspectWhenPingFailsButRequestedNodesSucceedToPing() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let probeA = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefA = local._resolveKnownRemote(probeA.ref, onRemoteSystem: remote)
        let probeB = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefB = local._resolveKnownRemote(probeB.ref, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRefA, remoteProbeRefB]) {
            $0.failureDetector.pingTimeout = .milliseconds(50)
        }

        let pingProbe: ActorTestProbe<SWIM.Message>
        let suspiciousProbe: ActorTestProbe<SWIM.Message>
        let suspiciousRemoteRef: ActorRef<SWIM.Message>
        // we take out the one member, to guarantee that the other one will be pinged, so we
        // can be sure to act on the correct reference, which otherwise would not be possible,
        // because of the randomness
        if swimState.nextMemberToPing()! == remoteProbeRefA {
            pingProbe = probeA
            suspiciousProbe = probeB
            suspiciousRemoteRef = remoteProbeRefB
        } else {
            pingProbe = probeB
            suspiciousProbe = probeA
            suspiciousRemoteRef = remoteProbeRefA
        }

        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: suspiciousProbe, reply: false)

        try expectPingRequest(for: suspiciousProbe.ref, on: pingProbe, reply: true)

        try holdStatus(.alive(incarnation: 0), for: suspiciousRemoteRef, on: ref, within: .seconds(1))
    }

    func test_SWIMMembershipShell_shouldMarkSuspectedMembersAsAliveWhenPingingSucceedsWithinSuspicionTimeout() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRef])
        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: true, incarnation: 1)

        try awaitStatus(.alive(incarnation: 1), for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_SWIMMembershipShell_shouldMarkSuspectedMembersAsDeadAfterConfiguredSuspicionTimeout() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRef])
        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false)

        try awaitStatus(.suspect(incarnation: 0), for: remoteProbeRef, on: ref, within: .seconds(1))

        for _ in 0 ..< swimState.settings.failureDetector.suspicionTimeoutMax {
            ref.tell(.local(.pingRandomMember))
            try expectPing(on: p, reply: false)
        }

        // We need to trigger an additional ping to advance the protocol period
        // and have the SWIM actor mark the remote node as dead
        ref.tell(.local(.pingRandomMember))

        try awaitStatus(.dead, for: remoteProbeRef, on: ref, within: .seconds(1))
    }

    func test_SWIMMembershipShell_shouldSendGossipInPing() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRef = local._resolveKnownRemote(p.ref, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRef]) {
            $0.failureDetector.pingTimeout = .milliseconds(50)
        }

        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: p, reply: false) {
            switch $0 {
            case .membership(let memberships):
                memberships.count.shouldEqual(1)
                memberships.contains(SWIM.Member(ref: p.ref, status: .alive(incarnation: 0))).shouldBeTrue()
            case .none:
                throw p.error("Expected gossip, but got `.none`")
            }
        }
    }

    func test_SWIMMembershipShell_shouldSendGossipInAck() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let p = remoteTestKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let remoteProbeRef = remote._resolveKnownRemote(p.ref, onRemoteSystem: remote)
        let memberProbe = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteMemberRef = remote._resolveKnownRemote(memberProbe.ref, onRemoteSystem: remote)

        let ref = try local.spawn(SWIMMembershipShell.ready(state: makeSwimState(members: [remoteMemberRef])), name: "SWIM")

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: remoteProbeRef, payload: .none)))

        let response = try p.expectMessage()
        switch response.payload {
        case .membership(let memberships):
            memberships.count.shouldEqual(1)
            memberships.contains(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0))).shouldBeTrue()
        case .none:
            throw p.error("Expected gossip, but got `.none`")
        }
    }

    func test_SWIMMembershipShell_shouldSendGossipInPingReq() throws {
        setUpBoth()

        local.join(address: remoteUniqueAddress.address)
        try assertAssociated(local, with: remoteUniqueAddress)

        let probeA = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefA = local._resolveKnownRemote(probeA.ref, onRemoteSystem: remote)
        let probeB = remoteTestKit.spawnTestProbe(expecting: SWIM.Message.self)
        let remoteProbeRefB = local._resolveKnownRemote(probeB.ref, onRemoteSystem: remote)

        let swimState: SWIMMembershipShell.State = makeSwimState(members: [remoteProbeRefA, remoteProbeRefB]) {
            $0.failureDetector.pingTimeout = .milliseconds(50)
        }

        let pingProbe: ActorTestProbe<SWIM.Message>
        let suspiciousProbe: ActorTestProbe<SWIM.Message>
        // we take out the one member, to guarantee that the other one will be pinged, so we
        // can be sure to act on the correct reference, which otherwise would not be possible,
        // because of the randomness
        if swimState.nextMemberToPing()! == remoteProbeRefA {
            pingProbe = probeA
            suspiciousProbe = probeB
        } else {
            pingProbe = probeB
            suspiciousProbe = probeA
        }

        let ref = try local.spawn(SWIMMembershipShell.ready(state: swimState), name: "SWIM")

        ref.tell(.local(.pingRandomMember))

        try expectPing(on: suspiciousProbe, reply: false)

        try expectPingRequest(for: suspiciousProbe.ref, on: pingProbe, reply: false) {
            switch $0 {
            case .membership(let memberships):
                memberships.count.shouldEqual(2)
                print("\(memberships)")
                memberships.contains(SWIM.Member(ref: suspiciousProbe.ref, status: .alive(incarnation: 0))).shouldBeTrue()
                memberships.contains(SWIM.Member(ref: pingProbe.ref, status: .alive(incarnation: 0))).shouldBeTrue()
            case .none:
                throw pingProbe.error("Expected gossip, but got `.none`")
            }
        }
    }

    func test_SWIMMembershipShell_shouldSendGossipOnlyTheConfiguredNumberOfTimes() throws {
        setUpLocal()
        let p = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)
        let memberProbe = localTestKit.spawnTestProbe(expecting: SWIM.Message.self)

        let ref = try local.spawn(SWIMMembershipShell.ready(state: makeSwimState(members: [memberProbe.ref])), name: "SWIM")

        for _ in 0 ..< SWIM.Settings.default.gossip.maxGossipCountPerMessage {
            ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

            let response = try p.expectMessage()

            switch response.payload {
            case .membership(let memberships):
                memberships.contains(SWIM.Member(ref: memberProbe.ref, status: .alive(incarnation: 0))).shouldBeTrue()
            case .none:
                throw p.error("Expected gossip, but got `.none`")
            }
        }

        ref.tell(.remote(.ping(lastKnownStatus: .alive(incarnation: 0), replyTo: p.ref, payload: .none)))

        let response = try p.expectMessage()

        response.from.shouldEqual(ref)
        response.incarnation.shouldEqual(0)
        switch response.payload {
        case .membership:
            throw p.error("Expected no gossip, but got [\(response.payload)]")
        case .none:
            ()
        }
    }

    func test_SWIMMembershipShell_shouldConvergeStateThroughGossip() throws {
        setUpBoth()
        let membershipProbe = localTestKit.spawnTestProbe(expecting: SWIM.MembershipState.self)
        let pingProbe = localTestKit.spawnTestProbe(expecting: SWIM.Ack.self)

        var swimSettings: SWIMSettings = .default
        swimSettings.failureDetector.probeInterval = .milliseconds(50)

        let localRef = try local.spawn(SWIMMembershipShell.behavior(settings: swimSettings), name: "SWIM-A")
        let remoteRef = try remote.spawn(SWIMMembershipShell.behavior(settings: swimSettings), name: "SWIM-B")

        let localRefRemote = remote._resolveKnownRemote(localRef, onRemoteSystem: local)

        remoteRef.tell(.remote(.pingReq(target: localRefRemote, lastKnownStatus: .alive(incarnation: 0), replyTo: pingProbe.ref, payload: .none)))

        try localTestKit.eventually(within: .seconds(3)) {
            localRef.tell(.remote(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusA = try membershipProbe.expectMessage()
            print("Status A: \(statusA)")

            remoteRef.tell(.remote(.getMembershipState(replyTo: membershipProbe.ref)))
            let statusB = try membershipProbe.expectMessage()
            print("Status B: \(statusB)")

            guard statusA.membershipStatus.count == 2, statusB.membershipStatus.count == 2 else {
                throw Boom()
            }

            for (ref, status) in statusA.membershipStatus {
                // there has to be a better way to do this, but that paths are
                // different, because they reside on different nodes, so we
                // compare only the segments, which are unique per instance
                guard let (_, otherStatus) = statusB.membershipStatus.first(where: { $0.key.path.path.segments == ref.path.path.segments }), otherStatus == status else {
                    throw Boom()
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    func expectPing(on probe: ActorTestProbe<SWIM.Message>, reply: Bool, incarnation: SWIM.Incarnation = 0,
                    file: StaticString = #file, line: UInt = #line, column: UInt = #column,
                    assertPayload: (SWIM.Payload) throws -> Void = { _ in }) throws {
        switch try probe.expectMessage(file: file, line: line, column: column) {
        case .remote(.ping(_, let replyTo, let payload)):
            try assertPayload(payload)
            if reply {
                replyTo.tell(SWIM.Ack(from: probe.ref, incarnation: incarnation, payload: .none))
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
                replyTo.tell(SWIM.Ack(from: toPing, incarnation: incarnation, payload: .none))
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
            membershipShell.tell(.remote(.getMembershipState(replyTo: stateProbe.ref)))
            guard try stateProbe.expectMessage().membershipStatus[member] == status else {
                throw Boom()
            }
        }
    }

    func holdStatus(_ status: SWIM.Status, for member: ActorRef<SWIM.Message>,
                    on membershipShell: ActorRef<SWIM.Message>, within timeout: TimeAmount,
                    file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let stateProbe = localTestKit.spawnTestProbe(expecting: SWIM.MembershipState.self)
        try localTestKit.assertHolds(for: timeout, file: file, line: line, column: column) {
            membershipShell.tell(.remote(.getMembershipState(replyTo: stateProbe.ref)))
            guard try stateProbe.expectMessage().membershipStatus[member] == status else {
                throw Boom()
            }
        }
    }

    func makeSwimState(members: [ActorRef<SWIM.Message>], makeSettings: (inout SWIM.Settings) -> Void = { _ in }) -> SWIMMembershipShell.State {
        var memberStatus: [ActorRef<SWIM.Message>: SWIM.Status] = [:]
        for member in members {
            memberStatus[member] = .alive(incarnation: 0)
        }
        return makeSwimState(members: memberStatus, makeSettings: makeSettings)
    }

    func makeSwimState(members: [ActorRef<SWIM.Message>: SWIM.Status], makeSettings: (inout SWIM.Settings) -> Void = { _ in }) -> SWIMMembershipShell.State {
        var settings = SWIM.Settings()
        makeSettings(&settings)
        let state = SWIMMembershipShell.State(settings)
        for (member, status) in members {
            state.addMember(member, status: status)
        }
        return state
    }
}
