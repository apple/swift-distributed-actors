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

final class SWIMInstanceTests: ActorSystemTestBase {
    let testNode = UniqueNode(systemName: "test", host: "test", port: 12345, nid: UniqueNodeID(0))

    var clusterTestProbe: ActorTestProbe<ClusterShell.Message>!

    override func setUp() {
        super.setUp()
        self.clusterTestProbe = self.testKit.spawnTestProbe()
    }

    override func tearDown() {
        super.tearDown()
        self.clusterTestProbe = nil
    }

    func test_addMember_shouldAddAMemberWithTheSpecifiedStatusAndCurrentProtocolPeriod() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default, myShellMyself: myself.ref, myNode: self.testNode)
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
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.notMyself(myself).shouldBeFalse()
    }

    func test_notMyself_shouldDetectRandomNotMyselfActor() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let someone = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.notMyself(someone).shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking members as various statuses

    func test_mark_shouldNotApplyEqualStatus() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.addMember(probe.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]), shouldSucceed: false)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyNewerStatus() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))

        for i: SWIM.Incarnation in 0 ... 5 {
            swim.incrementProtocolPeriod()
            try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: SWIM.Incarnation(i), suspectedBy: [self.testNode]), shouldSucceed: true)
            try self.validateMark(swim: swim, member: probe.ref, status: .alive(incarnation: SWIM.Incarnation(i + 1)), shouldSucceed: true)
        }

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(6)
    }

    func test_mark_shouldNotApplyOlderStatus_suspect() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        // ==== Suspect member -----------------------------------------------------------------------------------------
        let suspectMember = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        swim.addMember(suspectMember.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: suspectMember.ref, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, member: suspectMember.ref, status: .alive(incarnation: 1), shouldSucceed: false)

        swim.member(for: suspectMember.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldNotApplyOlderStatus_unreachable() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        let unreachableMember = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        swim.addMember(unreachableMember.ref, status: .unreachable(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: unreachableMember.ref, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, member: unreachableMember.ref, status: .alive(incarnation: 1), shouldSucceed: false)

        swim.member(for: unreachableMember.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyDead() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.addMember(probe.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .dead, shouldSucceed: true)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(1)
    }

    func test_mark_shouldNotApplyAnyStatusIfAlreadyDead() throws {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.addMember(probe.ref, status: .dead)
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, member: probe.ref, status: .alive(incarnation: 99), shouldSucceed: false)
        try self.validateMark(swim: swim, member: probe.ref, status: .suspect(incarnation: 99, suspectedBy: [self.testNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, member: probe.ref, status: .dead, shouldSucceed: false)

        swim.member(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling ping-req responses

    func test_onPingRequestResponse_allowsSuspectNodeToRefuteSuspicion() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        // p3 is suspect already...
        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.addMember(p3, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))

        // Imagine: we asked p2 to ping p3
        // p3 pings p2, gets an ack back -- and there p2 had to bump its incarnation number // TODO test for that, using Swim.instance?

        // and now we get an `ack` back, p2 claims that p3 is indeed alive!
        _ = swim.onPingRequestResponse(.success(.ack(target: p3, incarnation: 2, payload: .none)), pingedMember: p3)
        // may print the result for debugging purposes if one wanted to

        // p3 should be alive; after all, p2 told us so!
        swim.member(for: p3)!.isAlive.shouldBeTrue()
    }

    func test_onPingRequestResponse_ignoresTooOldRefutations() {
        let p1 = self.testKit.spawnTestProbe("p1", expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe("p2", expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe("p3", expecting: SWIM.Message.self).ref

        // p3 is suspect already...
        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.addMember(p3, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))

        // Imagine: we asked p2 to ping p3
        // p3 pings p2, yet p2 somehow didn't bump its incarnation... so we should NOT accept its refutation

        // and now we get an `ack` back, p2 claims that p3 is indeed alive!
        _ = swim.onPingRequestResponse(.success(.ack(target: p3, incarnation: 1, payload: .none)), pingedMember: p3)
        // may print the result for debugging purposes if one wanted to

        // p3 should be alive; after all, p2 told us so!
        swim.member(for: p3)!.isSuspect.shouldBeTrue()
    }

    func test_onPingRequestResponse_storeIndividualSuspicions() throws {
        var settings: SWIM.Settings = .default
        settings.lifeguard.maxIndependentSuspicions = 10
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let secondTestNode = self.testNode.copy(UniqueNodeID(1))

        swim.addMember(p2, status: .suspect(incarnation: 1, suspectedBy: [secondTestNode]))

        struct TestError: Error {}

        _ = swim.onPingRequestResponse(.failure(TestError()), pingedMember: p2)
        let resultStatus = swim.member(for: p2)!.status
        if case .suspect(_, let confimrations) = resultStatus {
            confimrations.shouldEqual([secondTestNode, testNode])
        } else {
            throw self.testKit.fail("Expected `.suspected(_, Set(0,1))`, got \(resultStatus)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: receive a ping and reply to it

    func test_onPing_shouldOfferAckMessageWithMyselfReference() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(p2, status: .alive(incarnation: 0))

        let res = swim.onPing()

        switch res {
        case .reply(.ack(let pinged, _, _)):
            pinged.shouldEqual(p1) // which was added as myself to this swim instance
        case let reply:
            throw self.testKit.error("Expected .ack, but got \(reply)")
        }
    }

    func test_onPing_withAlive_shouldReplyWithAlive_withIncrementedIncarnation() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        // from our perspective, all nodes are alive...
        swim.addMember(p2, status: .alive(incarnation: 0))

        // Imagine: p3 pings us, it suspects us (!)
        // we (p1) receive the ping and want to refute the suspicion, we are Still Alive:
        // (p3 has heard from someone that we are suspect in incarnation 10 (for some silly reason))
        let res = swim.onPing()

        switch res {
        case .reply(.ack(_, let incarnation, _)):
            // did not have to increment its incarnation number:
            incarnation.shouldEqual(0)
        case let reply:
            throw self.testKit.error("Expected .ack ping response, but got \(reply)")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Detecting when a change is "effective"

    func test_MarkedDirective_isEffectiveChange() {
        let p = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        SWIM.Instance.MemberStatusChange(fromStatus: nil, member: SWIM.Member(ref: p.ref, status: .alive(incarnation: 1), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: nil, member: SWIM.Member(ref: p.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: nil, member: SWIM.Member(ref: p.ref, status: .unreachable(incarnation: 1), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: nil, member: SWIM.Member(ref: p.ref, status: .dead, protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)

        SWIM.Instance.MemberStatusChange(fromStatus: .alive(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .alive(incarnation: 2), protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .alive(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]), protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .alive(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .unreachable(incarnation: 1), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .alive(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .dead, protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)

        SWIM.Instance.MemberStatusChange(fromStatus: .suspect(incarnation: 1, suspectedBy: [self.testNode]), member: SWIM.Member(ref: p.ref, status: .alive(incarnation: 2), protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .suspect(incarnation: 1, suspectedBy: [self.testNode]), member: SWIM.Member(ref: p.ref, status: .suspect(incarnation: 2, suspectedBy: [self.testNode]), protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .suspect(incarnation: 1, suspectedBy: [self.testNode]), member: SWIM.Member(ref: p.ref, status: .unreachable(incarnation: 2), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .suspect(incarnation: 1, suspectedBy: [self.testNode]), member: SWIM.Member(ref: p.ref, status: .dead, protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)

        SWIM.Instance.MemberStatusChange(fromStatus: .unreachable(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .alive(incarnation: 2), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .unreachable(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .suspect(incarnation: 2, suspectedBy: [self.testNode]), protocolPeriod: 1))
            .isReachabilityChange.shouldBeTrue(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .unreachable(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .unreachable(incarnation: 2), protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
        SWIM.Instance.MemberStatusChange(fromStatus: .unreachable(incarnation: 1), member: SWIM.Member(ref: p.ref, status: .dead, protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)

        // those are illegal, but even IF they happened at least we'd never bubble them up to high level
        // moving from .dead to any other state is illegal and will assert
        // illegal, precondition crash: SWIM.Instance.MemberStatusChange(fromStatus: .dead, member: SWIM.Member(ref: p.ref, status: .alive(incarnation: 2), protocolPeriod: 1))
        // illegal, precondition crash: SWIM.Instance.MemberStatusChange(fromStatus: .dead, member: SWIM.Member(ref: p.ref, status: .suspect(incarnation: 2), protocolPeriod: 1))
        // illegal, precondition crash: SWIM.Instance.MemberStatusChange(fromStatus: .dead, member: SWIM.Member(ref: p.ref, status: .unreachable(incarnation: 2), protocolPeriod: 1))
        SWIM.Instance.MemberStatusChange(fromStatus: .dead, member: SWIM.Member(ref: p.ref, status: .dead, protocolPeriod: 1))
            .isReachabilityChange.shouldBeFalse(line: #line - 1)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling gossip about the receiving node

    func test_onGossipPayload_myself_withAlive() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let currentIncarnation = swim.incarnation

        let myselfMember = swim.member(for: myself)!

        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .applied(_, _, let warning) where warning == nil:
            ()
        default:
            throw self.testKit.fail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndSameIncarnation_shouldIncrementIncarnation() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.member(for: myself)!
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.testNode])

        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation + 1)

        switch res {
        case .applied(_, _, let warning) where warning == nil:
            ()
        default:
            throw self.testKit.fail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndLowerIncarnation_shouldNotIncrementIncarnation() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        var currentIncarnation = swim.incarnation

        var myselfMember = swim.member(for: myself)!

        // necessary to increment incarnation
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.testNode])
        _ = swim.onGossipPayload(about: myselfMember)

        currentIncarnation = swim.incarnation

        myselfMember.status = .suspect(incarnation: currentIncarnation - 1, suspectedBy: [self.testNode]) // purposefully "previous"
        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .ignored(nil, nil):
            ()
        default:
            throw self.testKit.fail("Expected [ignored(level: nil, message: nil)], got [\(res)]")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndHigherIncarnation_shouldNotIncrementIncarnation() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.member(for: myself)!

        myselfMember.status = .suspect(incarnation: currentIncarnation + 6, suspectedBy: [self.testNode])
        let res = swim.onGossipPayload(about: myselfMember)

        swim.incarnation.shouldEqual(currentIncarnation)

        switch res {
        case .applied(nil, _, let warning) where warning != nil:
            ()
        default:
            throw self.testKit.fail("Expected `.none(message)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withDead() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        var myselfMember = swim.member(for: myself)!
        myselfMember.status = .dead
        let res = swim.onGossipPayload(about: myselfMember)

        let myMember = swim.member(for: myself)!
        myMember.status.shouldEqual(.dead)

        switch res {
        case .applied(.some(let change), _, _) where change.toStatus.isDead:
            change.member.shouldEqual(myselfMember)
        default:
            throw self.testKit.fail("Expected `.applied(.some(change to dead)`, got: \(res)")
        }
    }

    func test_onGossipPayload_other_withDead() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let other = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .dead
        let res = swim.onGossipPayload(about: otherMember)

        switch res {
        case .applied(.some(let change), _, _) where change.toStatus.isDead:
            change.member.shouldEqual(otherMember)
        default:
            throw self.testKit.fail("Expected `.applied(.some(change to dead))`, got \(res)")
        }
    }

    func test_onGossipPayload_other_withNewSuspicion_shouldStoreIndividulalSuspicions() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let other = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]))
        let secondTestNode = self.testNode.copy(UniqueNodeID(1))
        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [secondTestNode])
        let res = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change), _, _) = res,
            case .suspect(_, let confirmation) = change.toStatus {
            confirmation.shouldEqual([testNode, secondTestNode])
        } else {
            throw self.testKit.fail("Expected `.applied(.some(suspect with multiple suspectedBy))`, got \(res)")
        }
    }

    func test_onGossipPayload_other_shouldNotApplyGossip_whenHaveEnoughSuspectedBy() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let other = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let saturatedSuspectedByList = (1 ... swim.settings.lifeguard.maxIndependentSuspicions).map { UniqueNode(systemName: "test", host: "test", port: 12345, nid: UniqueNodeID(UInt32($0))) }

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: Set(saturatedSuspectedByList)))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.testNode])
        let res = swim.onGossipPayload(about: otherMember)
        guard case .ignored = res else {
            throw self.testKit.fail("Expected `.ignored(_, _)`, got \(res)")
        }
    }

    func test_onGossipPayload_other_shouldNotExceedMaximumSuspectedBy() throws {
        var settings: SWIMSettings = .default
        settings.lifeguard.maxIndependentSuspicions = 3
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(settings, myShellMyself: myself, myNode: self.testNode)
        let other = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let secondTestNode = self.testNode.copy(UniqueNodeID(1))
        let thirdTestNode = self.testNode.copy(UniqueNodeID(2))
        let fourthTestNode = self.testNode.copy(UniqueNodeID(3))

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.testNode, secondTestNode]))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [thirdTestNode, fourthTestNode])
        let res = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change), _, _) = res,
            case .suspect(_, let confirmation) = change.toStatus {
            confirmation.count.shouldEqual(swim.settings.lifeguard.maxIndependentSuspicions)
        } else {
            throw self.testKit.fail("Expected `.applied(.some(suspectedBy)) where suspectedBy.count = maxIndependentSuspicions`, got \(res)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increment-ing counters

    func test_incrementProtocolPeriod_shouldIncrementTheProtocolPeriodNumberByOne() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        for i in 0 ..< 10 {
            swim.protocolPeriod.shouldEqual(i)
            swim.incrementProtocolPeriod()
        }
    }

    func test_members_shouldContainAllAddedMembers() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

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
    // MARK: Modifying LHA-probe multiplier

    func test_onPingRequestResponse_incrementLHAMultiplier_whenMissedNack() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(p2, status: .alive(incarnation: 0))
        struct TestError: Error {}
        _ = swim.onPingRequestResponse(.failure(TestError()), pingedMember: p2)
        swim.localHealthMultiplier.shouldEqual(1)
    }

    func test_onPingRequestResponse_decrementLHAMultiplier_whenGotAck() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1
        _ = swim.onPingRequestResponse(.success(.ack(target: p2, incarnation: 0, payload: .none)), pingedMember: p2)
        swim.localHealthMultiplier.shouldEqual(0)
    }

    func test_onPingRequestResponse_notIncrementLHAMultiplier_whenSeeOldSuspicion_onGossip() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)
        // first suspicion is for current incarnation, should increase LHA counter
        _ = swim.onGossipPayload(about: SWIMMember(ref: p1, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), protocolPeriod: 0))
        swim.localHealthMultiplier.shouldEqual(1)
        // second suspicion is for a stale incarnation, should ignore
        _ = swim.onGossipPayload(about: SWIMMember(ref: p1, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), protocolPeriod: 0))
        swim.localHealthMultiplier.shouldEqual(1)
    }

    func test_onPingRequestResponse_incrementLHAMultiplier_whenRefuteSuspicion_onGossip() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        _ = swim.onGossipPayload(about: SWIMMember(ref: p1, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), protocolPeriod: 0))
        swim.localHealthMultiplier.shouldEqual(1)
    }

    func test_onPingRequestResponse_dontChangeLHAMultiplier_whenGotNack() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        swim.addMember(p2, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1

        _ = swim.onPingRequestResponse(.success(.nack(target: p2)), pingedMember: p2)
        swim.localHealthMultiplier.shouldEqual(1)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Selecting members to ping

    func test_nextMemberToPing_shouldReturnEachMemberOnceBeforeRepeatingAndKeepOrder() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        let memberCount = 10
        var members: Set<ActorRef<SWIM.Message>> = []
        for _ in 0 ..< memberCount {
            let p = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
            members.insert(p.ref)
            swim.addMember(p.ref, status: .alive(incarnation: 0))
        }

        var seenMembers: [ActorRef<SWIM.Message>] = []
        for _ in 0 ..< memberCount {
            guard let member = swim.nextMemberToPing() else {
                throw self.testKit.fail("Could not fetch member to ping")
            }

            seenMembers.append(member)
            members.remove(member).shouldNotBeNil()
        }

        members.shouldBeEmpty()

        // should loop around and we should encounter all the same members now
        for _ in 0 ..< memberCount {
            guard let member = swim.nextMemberToPing() else {
                throw self.testKit.fail("Could not fetch member to ping")
            }

            seenMembers.removeFirst().shouldEqual(member)
        }
    }

    func test_addMember_shouldNotAddLocalNodeForPinging() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let swim = SWIM.Instance(.default, myShellMyself: probe.ref, myNode: self.testNode)

        swim.isMember(probe.ref).shouldBeTrue()
        swim.nextMemberToPing().shouldBeNil()
    }

    func test_nextMemberToPingRequest() {
        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

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
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))
        swim.member(for: probe.ref)!.status.shouldEqual(.alive(incarnation: 0))

        _ = swim.mark(probe.ref, as: .suspect(incarnation: 99, suspectedBy: [self.testNode]))
        swim.member(for: probe.ref)!.status.shouldEqual(.suspect(incarnation: 99, suspectedBy: [self.testNode]))
    }

    func test_member_shouldWorkForMyself() {
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: p1, myNode: self.testNode)

        swim.addMember(p2, status: .alive(incarnation: 10))

        let member = swim.member(for: p1)!
        member.ref.shouldEqual(p1)
        member.isAlive.shouldBeTrue()
        member.status.shouldEqual(.alive(incarnation: 0))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: (Round up the usual...) Suspects

    func test_suspects_shouldContainOnlySuspectedNodes() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.addMember(p2, status: aliveAtZero)
        swim.addMember(p3, status: aliveAtZero)
        swim.memberCount.shouldEqual(4) // three new nodes + myself

        self.validateSuspects(swim, expected: [])

        swim.mark(p1, as: .suspect(incarnation: 0, suspectedBy: [self.testNode])).shouldEqual(.applied(previousStatus: aliveAtZero, currentStatus: .suspect(incarnation: 0, suspectedBy: [self.testNode])))
        self.validateSuspects(swim, expected: [p1])

        _ = swim.mark(p3, as: .suspect(incarnation: 0, suspectedBy: [self.testNode]))
        self.validateSuspects(swim, expected: [p1, p3])

        _ = swim.mark(p2, as: .suspect(incarnation: 0, suspectedBy: [self.testNode]))
        _ = swim.mark(p1, as: .alive(incarnation: 1))
        self.validateSuspects(swim, expected: [p2, p3])
    }

    func test_suspects_shouldMark_whenBiggerSuspicionList() {
        var settings: SWIM.Settings = .default
        settings.lifeguard.maxIndependentSuspicions = 10
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.memberCount.shouldEqual(2)
        let secondTestNode = self.testNode.copy(UniqueNodeID(1))

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.testNode])
        swim.mark(p1, as: oldStatus).shouldEqual(.applied(previousStatus: aliveAtZero, currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [p1])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.testNode, secondTestNode])
        swim.mark(p1, as: newStatus).shouldEqual(.applied(previousStatus: oldStatus, currentStatus: newStatus))
        self.validateSuspects(swim, expected: [p1])
    }

    func test_suspects_shouldNotMark_whenSmallerSuspicionList() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)
        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.memberCount.shouldEqual(2)
        let secondTestNode = self.testNode.copy(UniqueNodeID(1))

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.testNode, secondTestNode])
        swim.mark(p1, as: oldStatus).shouldEqual(.applied(previousStatus: aliveAtZero, currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [p1])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.testNode])
        swim.mark(p1, as: newStatus).shouldEqual(.ignoredDueToOlderStatus(currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [p1])
    }

    func test_memberCount_shouldNotCountDeadMembers() {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(p1, status: aliveAtZero)
        swim.addMember(p2, status: aliveAtZero)
        swim.addMember(p3, status: aliveAtZero)
        swim.memberCount.shouldEqual(4)

        swim.mark(p1, as: .dead)
        swim.memberCount.shouldEqual(3)

        swim.mark(p2, as: .unreachable(incarnation: 19))
        swim.memberCount.shouldEqual(3) // unreachable is still "part of the membership" as far as we are concerned

        swim.mark(p2, as: .dead)
        swim.memberCount.shouldEqual(2) // dead is not part of membership
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: makeGossipPayload

    func test_makeGossipPayload_shouldGossipAboutSelf_whenNoMembers() throws {
        let myself = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(.default, myShellMyself: myself, myNode: self.testNode)

        try self.validateGossip(swim: swim, expected: [.init(ref: myself, status: .alive(incarnation: 0), protocolPeriod: 0)])
    }

    func test_makeGossipPayload_shouldReturnEachEntryOnlyTheConfiguredNumberOfTimes() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let shell = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(settings, myShellMyself: shell, myNode: self.testNode)

        let p1 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(p1.ref, status: .alive(incarnation: 0))
        let myself = SWIMMember(ref: shell, status: .alive(incarnation: 0), protocolPeriod: 0)
        try self.validateGossip(swim: swim, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0), protocolPeriod: 0), myself])

        swim.addMember(p2.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]))
        try self.validateGossip(swim: swim, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0), protocolPeriod: 0), .init(ref: p2.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]), protocolPeriod: 0), myself])

        swim.addMember(p3.ref, status: .dead)
        try self.validateGossip(swim: swim, expected: [.init(ref: p2.ref, status: .suspect(incarnation: 1, suspectedBy: [self.testNode]), protocolPeriod: 0), .init(ref: p3.ref, status: .dead, protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [.init(ref: p3.ref, status: .dead, protocolPeriod: 0)])
        try self.validateGossip(swim: swim, expected: [])
    }

    func test_makeGossipPayload_shouldResetCounterWhenStatusChanged() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let shell = self.testKit.spawnTestProbe(expecting: SWIM.Message.self).ref
        let swim = SWIM.Instance(settings, myShellMyself: shell, myNode: self.testNode)

        let probe = self.testKit.spawnTestProbe(expecting: SWIM.Message.self)

        swim.addMember(probe.ref, status: .alive(incarnation: 0))
        let myself = SWIMMember(ref: shell, status: .alive(incarnation: 0), protocolPeriod: 0)

        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .alive(incarnation: 0), protocolPeriod: 0), myself])

        _ = swim.mark(probe.ref, as: .suspect(incarnation: 0, suspectedBy: [self.testNode]))
        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), protocolPeriod: 0), myself])
        try self.validateGossip(swim: swim, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0, suspectedBy: [self.testNode]), protocolPeriod: 0)])
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
        let payload = swim.makeGossipPayload(to: nil)
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

extension UniqueNode {
    func copy(_ nid: UniqueNodeID) -> UniqueNode {
        UniqueNode(node: self.node, nid: nid)
    }
}
