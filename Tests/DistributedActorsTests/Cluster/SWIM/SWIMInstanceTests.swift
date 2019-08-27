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
import XCTest

final class SWIMInstanceTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!
    var clusterTestProbe: ActorTestProbe<ClusterShell.Message>!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
        self.clusterTestProbe = self.testKit.spawnTestProbe()
    }

    override func tearDown() {
        self.system.shutdown()
    }

    func test_addMember_shouldAddAMemberWithTheSpecifiedStatusAndCurrentProtocolPeriod() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)
        let status: SWIM.Status = .alive(incarnation: 1)

        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()

        swim.isMember(probe.ref).shouldBeFalse()
        _ = swim.addMember(probe.ref, status: status)

        swim.isMember(probe.ref).shouldBeTrue()
        let member = swim.member(for: probe.ref)!
        member.protocolPeriod.shouldEqual(swim.protocolPeriod)
        member.status.shouldEqual(status)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Detecting myself

    func test_notMyself_shouldDetectRemoteVersionOfSelf() {
        let shell = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let swim = SWIM.Instance(.default)
        swim.addMyself(shell)

        swim.notMyself(shell).shouldBeFalse()
    }

    func test_notMyself_shouldDetectRandomNotMyselfActor() {
        let shell = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let someone = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let swim = SWIM.Instance(.default)
        swim.addMyself(shell)

        swim.notMyself(someone).shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking members as various statuses

    func test_mark_shouldNotApplyEqualStatus() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .suspect(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: 1), shouldSucceed: false)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyNewerStatus() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))

        for i in 0...5 {
            swim.incrementProtocolPeriod()
            try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: SWIM.Incarnation(i)), shouldSucceed: true)
            try self.validateMark(swim: swim, member: probe.ref, status: .alive(incarnation: SWIM.Incarnation(i + 1)), shouldSucceed: true)
        }

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(6)
    }

    func test_mark_shouldNotApplyOlderStatus() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .suspect(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: 0), shouldSucceed: false)
        try self.validateMark(swim: swim, member: probe.ref, status: .alive(incarnation: 1), shouldSucceed: false)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyDead() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .suspect(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .dead, shouldSucceed: true)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(1)
    }

    func test_mark_shouldNotApplyAnyStatusIfAlreadyDead() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .dead)
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .alive(incarnation: 99), shouldSucceed: false)
        try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: 99), shouldSucceed: false)
        try self.validateMark(swim: swim, member: probe.ref, status: .dead, shouldSucceed: false)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling ping-req responses

    func test_onPingRequestResponse_allowsSuspectNodeToRefuteSuspicion() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        // p3 is suspect already...
        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.addMember(p3, status: .suspect(incarnation: 1))

        // Imagine: we asked p2 to ping p3
        // p3 pings p2, gets an ack back -- and there p2 had to bump its incarnation number // TODO test for that, using Swim.instance?

        // and now we get an `ack` back, p2 claims that p3 is indeed alive!
        _ = swim.onPingRequestResponse(.success(SWIM.Ack(pinged: p3, incarnation: 2, payload: .none)), pingedMember: p3)
        // may print the result for debugging purposes if one wanted to

        // p3 should be alive; after all, p2 told us so!
        swim.member(for: p3)!.isAlive.shouldBeTrue()
    }

    func test_onPingRequestResponse_ignoresTooOldRefutations() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(name: "p1", expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(name: "p2", expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(name: "p3", expecting: SWIM.Message.self).ref

        // p3 is suspect already...
        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.addMember(p3, status: .suspect(incarnation: 1))

        // Imagine: we asked p2 to ping p3
        // p3 pings p2, yet p2 somehow didn't bump its incarnation... so we should NOT accept its refutation

        // and now we get an `ack` back, p2 claims that p3 is indeed alive!
        _ = swim.onPingRequestResponse(.success(SWIM.Ack(pinged: p3, incarnation: 1, payload: .none)), pingedMember: p3)
        // may print the result for debugging purposes if one wanted to

        // p3 should be alive; after all, p2 told us so!
        swim.member(for: p3)!.isSuspect.shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: receive a ping and reply to it

    func test_onPing_shouldOfferAckMessageWithMyselfReference() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 0))

        let res = swim.onPing(lastKnownStatus: .alive(incarnation: 0))

        switch res {
        case .reply(let ack, _):
            ack.pinged.shouldEqual(p1) // which was added as myself to this swim instance
        }
    }

    func test_onPing_withAlive_shouldReplyWithAlive_withIncrementedIncarnation() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        // from our perspective, all nodes are alive...
        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 0))

        // Imagine: p3 pings us, it suspects us (!)
        // we (p1) receive the ping and want to refute the suspicion, we are Still Alive:
        // (p3 has heard from someone that we are suspect in incarnation 10 (for some silly reason))
        let res = swim.onPing(lastKnownStatus: .alive(incarnation: 0))

        switch res {
        case .reply(let ack, _):
            // did not have to increment its incarnation number:
            ack.incarnation.shouldEqual(0)
        }
    }

    func test_onPing_withSuspicion_shouldReplyWithAlive_withIncrementedIncarnation() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        // from our perspective, all nodes are alive...
        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 0))

        // Imagine: p2 pings us, it suspects us (!)
        // we (p1) receive the ping and want to refute the suspicion, we are Still Alive:
        // (p2 has heard from someone that we are suspect in incarnation 10 (for some silly reason))
        let res = swim.onPing(lastKnownStatus: .suspect(incarnation: 0))

        switch res {
        case .reply(let ack, _):
            ack.incarnation.shouldEqual(1) // it incremented its incarnation number in order to refute the suspicion
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling gossip about the receiving node

    func test_onGossipPayload_myself_withAlive() throws {
        let swim = SWIM.Instance(.default)
        let currentIncarnation = swim.incarnation

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)
        let myselfMember = swim.member(for: myself)!

        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .applied(_, let warning) where warning == nil:
            ()
        default:
            throw self.testKit.fail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndSameIncarnation_shouldIncrementIncarnation() throws {
        let swim = SWIM.Instance(.default)
        let currentIncarnation = swim.incarnation

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)
        var myselfMember = swim.member(for: myself)!
        myselfMember.status = .suspect(incarnation: currentIncarnation)

        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation + 1)

        switch res {
        case .applied(_, let warning) where warning == nil:
            ()
        default:
            throw self.testKit.fail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndLowerIncarnation_shouldNotIncrementIncarnation() throws {
        let swim = SWIM.Instance(.default)
        var currentIncarnation = swim.incarnation

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)
        var myselfMember = swim.member(for: myself)!

        // necessary to increment incarnation
        myselfMember.status = .suspect(incarnation: currentIncarnation)
        _ = swim.onGossipPayload(about: myselfMember)

        currentIncarnation = swim.incarnation

        myselfMember.status = .suspect(incarnation: currentIncarnation - 1) // purposefully "previous"
        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .applied(nil, nil):
            ()
        default:
            throw self.testKit.fail("Expected [applied(level: nil, message: nil)], got [\(res)]")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndHigherIncarnation_shouldNotIncrementIncarnation() throws {
        let swim = SWIM.Instance(.default)
        let currentIncarnation = swim.incarnation

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)
        var myselfMember = swim.member(for: myself)!

        myselfMember.status = .suspect(incarnation: currentIncarnation + 6)
        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .applied(_, let warning) where warning != nil:
            ()
        default:
            throw self.testKit.fail("Expected `.none(message)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withDead() throws {
        let swim = SWIM.Instance(.default)

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)

        var myselfMember = swim.member(for: myself)!
        myselfMember.status = .dead
        let res = swim.onGossipPayload(about: myselfMember)

        switch res {
        case .confirmedDead(let member):
            member.shouldEqual(myselfMember)
        default:
            throw self.testKit.fail("Expected `.confirmedDead`, got \(res)")
        }
    }

    func test_onGossipPayload_other_withDead() throws {
        let swim = SWIM.Instance(.default)

        let myself = try system.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMyself(myself)

        let other = try system.spawn("SWIM-B", SWIM.Shell(swim, clusterRef: self.clusterTestProbe.ref).ready)
        swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .dead
        let res = swim.onGossipPayload(about: otherMember)

        switch res {
        case .confirmedDead(let member):
            member.shouldEqual(otherMember)
        default:
            throw self.testKit.fail("Expected `.confirmedDead`, got \(res)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increment-ing counters

    func test_incrementProtocolPeriod_shouldIncrementTheProtocolPeriodNumberByOne() {
        let swim = SWIM.Instance(.default)

        for i in 0..<10 {
            swim.protocolPeriod.shouldEqual(i)
            swim.incrementProtocolPeriod()
        }
    }

    func test_members_shouldContainAllAddedMembers() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(p1.ref, status: .alive(incarnation: 0))
        swim.addMember(p2.ref, status: .alive(incarnation: 0))
        swim.addMember(p3.ref, status: .alive(incarnation: 0))

        swim.isMember(p1.ref).shouldBeTrue()
        swim.isMember(p2.ref).shouldBeTrue()
        swim.isMember(p3.ref).shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Selecting members to ping

    func test_nextMemberToPing_shouldReturnEachMemberOnceBeforeRepeatingAndKeepOrder() throws {
        let swim = SWIM.Instance(.default)
        let memberCount = 10
        var members: Set<ActorRef<SWIM.Message>> = []
        for _ in 0..<memberCount {
            let p = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
            members.insert(p.ref)
            swim.addMember(p.ref, status: .alive(incarnation: 0))
        }

        var seenMembers: [ActorRef<SWIM.Message>] = []
        for _ in 0..<memberCount {
            guard let member = swim.nextMemberToPing() else {
                throw self.testKit.fail("Could not fetch member to ping")
            }

            seenMembers.append(member)
            members.remove(member).shouldNotBeNil()
        }

        members.shouldBeEmpty()

        // should loop around and we should encounter all the same members now
        for _ in 0..<memberCount {
            guard let member = swim.nextMemberToPing() else {
                throw self.testKit.fail("Could not fetch member to ping")
            }

            seenMembers.removeFirst().shouldEqual(member)
        }
    }

    func test_addMember_shouldNotAddLocalNodeForPinging() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMyself(probe.ref)

        swim.isMember(probe.ref).shouldBeTrue()
        swim.nextMemberToPing().shouldBeNil()
    }

    func test_nextMemberToPingRequest() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(p1.ref, status: .alive(incarnation: 0))
        swim.addMember(p2.ref, status: .alive(incarnation: 0))
        swim.addMember(p3.ref, status: .alive(incarnation: 0))

        let membersToPing = swim.membersToPingRequest(target: probe.ref)
        membersToPing.count.shouldEqual(3)

        let refsToPing = membersToPing.map {
            $0.ref
        }
        refsToPing.shouldContain(p1.ref)
        refsToPing.shouldContain(p2.ref)
        refsToPing.shouldContain(p3.ref)
    }

    func test_member_shouldReturnTheLastAssignedStatus() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))
        swim.member(for: probe.ref)!.status.shouldEqual(.alive(incarnation: 0))

        _ = swim.mark(probe.ref, as: .suspect(incarnation: 99))
        swim.member(for: probe.ref)!.status.shouldEqual(.suspect(incarnation: 99))
    }

    func test_member_shouldWorkForMyself() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default)

        swim.addMyself(p1)
        swim.addMember(p2, status: .alive(incarnation: 10))

        let member = swim.member(for: p1)!
        member.ref.shouldEqual(p1)
        member.isAlive.shouldBeTrue()
        member.status.shouldEqual(.alive(incarnation: 0))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: (Round up the usual...) Suspects

    func test_suspects_shouldContainOnlySuspectedNodes() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.addMember(p2, status: aliveAtZero)
        swim.addMember(p3, status: aliveAtZero)
        swim.memberCount.shouldEqual(3)

        self.validateSuspects(swim, expected: [])

        swim.mark(p1, as: .suspect(incarnation: 0)).shouldEqual(.applied(previousStatus: aliveAtZero))
        self.validateSuspects(swim, expected: [p1])

        _ = swim.mark(p3, as: .suspect(incarnation: 0))
        self.validateSuspects(swim, expected: [p1, p3])

        _ = swim.mark(p2, as: .suspect(incarnation: 0))
        _ = swim.mark(p1, as: .alive(incarnation: 1))
        self.validateSuspects(swim, expected: [p2, p3])
    }

    func test_memberCount_shouldNotCountDeadMembers() {
        let swim = SWIM.Instance(.default)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.addMember(p2, status: aliveAtZero)
        swim.addMember(p3, status: aliveAtZero)
        swim.memberCount.shouldEqual(3)

        swim.mark(p1, as: .dead)
        swim.memberCount.shouldEqual(2)

        swim.mark(p2, as: .unreachable(incarnation: 19))
        swim.memberCount.shouldEqual(2) // unreachable is still "part of the membership" as far as we are concerned

        swim.mark(p2, as: .dead)
        swim.memberCount.shouldEqual(1) // dead is not part of membership
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: makeGossipPayload

    func test_makeGossipPayload_shouldReturnNoneIfNothingToGossip() throws {
        let swim = SWIM.Instance(.default)
        try self.validateGossip(swim: swim, expected: [])
    }

    func test_makeGossipPayload_shouldReturnEachEntryOnlyTheConfiguredNumberOfTimes() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let swim = SWIM.Instance(settings)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(p1.ref, status: .alive(incarnation: 0))
        try self.validateGossip(swim: swim, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])

        swim.addMember(p2.ref, status: .suspect(incarnation: 1))
        try self.validateGossip(swim: swim, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0), protocolPeriod: 0), .init(ref: p2.ref, status: .suspect(incarnation: 1), protocolPeriod: 0)])

        swim.addMember(p3.ref, status: .dead)
        try self.validateGossip(swim: swim, expected: [.init(ref: p2.ref, status: .suspect(incarnation: 1), protocolPeriod: 0), .init(ref: p3.ref, status: .dead, protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [.init(ref: p3.ref, status: .dead, protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [])
    }

    func test_makeGossipPayload_shouldResetCounterWhenStatusChanged() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let swim = SWIM.Instance(settings)

        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))
        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .alive(incarnation: 0), protocolPeriod: 0)])

        _ = swim.mark(probe.ref, as: .suspect(incarnation: 0))
        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0), protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0), protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [])
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    func validateMark(swim: SWIM.Instance, member: ActorRef<SWIM.Message>, status: SWIM.Status, shouldSucceed: Bool, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let markResult = swim.mark(member, as: status)

        if shouldSucceed {
            guard case .applied = markResult else {
                throw self.testKit.fail("Expected `.applied`, got `\(markResult)`", file: file, line: line, column: column)
            }
        } else {
            guard case .ignoredDueToOlderStatus = markResult else {
                throw self.testKit.fail("Expected `.ignoredDueToOlderStatus`, got `\(markResult)`", file: file, line: line, column: column)
            }
        }
    }

    func validateSuspects(_ swim: SWIM.Instance, expected: Set<ActorRef<SWIM.Message>>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        Set(swim.suspects.map { $0.ref }).shouldEqual(expected, file: file, line: line, column: column)
    }

    func validateGossip(swim: SWIM.Instance, expected: Set<SWIM.Member>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let payload = swim.makeGossipPayload()
        if expected.isEmpty {
            guard case SWIM.Payload.none = payload else {
                throw self.testKit.fail("Expected `.none`, but got `\(payload)`", file: file, line: line, column: column)
            }
        } else {
            guard case SWIM.Payload.membership(let members) = payload else {
                throw self.testKit.fail("Expected `.membership`, but got `\(payload)`", file: file, line: line, column: column)
            }

            Set(members).shouldEqual(expected, file: file, line: line, column: column)
        }
    }
}
