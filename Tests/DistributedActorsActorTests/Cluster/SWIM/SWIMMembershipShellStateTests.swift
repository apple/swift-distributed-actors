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

import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

// TODO: Add more tests
class SWIMMembershipShellStateTests: XCTestCase {
    let system = ActorSystem("SupervisionTests")
    lazy var testKit = ActorTestKit(system)
    let localShellPath = try! UniqueActorPath(path: ActorPath(root: "test"), uid: .wellKnown)

    override func tearDown() {
        system.shutdown()
    }

    func test_addMember_shouldAddAMemberWithTheSpecifiedStatusAndCurrentProtocolPeriod() {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)
        let status: SWIM.Status = .alive(incarnation: 1)

        state.incrementProtocolPeriod()
        state.incrementProtocolPeriod()
        state.incrementProtocolPeriod()

        state.isMember(probe.ref).shouldBeFalse()

        state.addMember(probe.ref, status: status)

        state.isMember(probe.ref).shouldBeTrue()
        let info = state.membershipInfo(for: probe.ref)!
        info.protocolPeriod.shouldEqual(state.protocolPeriod)
        info.status.shouldEqual(status)
    }

    func test_mark_shouldNotApplyEqualStatus() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .suspect(incarnation: 1))
        state.incrementProtocolPeriod()

        try validateMark(state: state, member: probe.ref, status: .suspect(incarnation: 1), shouldSucceed: false)

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyNewerStatus() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .alive(incarnation: 0))

        for i in 0...5 {
            state.incrementProtocolPeriod()
            try validateMark(state: state, member: probe.ref, status: .suspect(incarnation: SWIM.Incarnation(i)), shouldSucceed: true)
            try validateMark(state: state, member: probe.ref, status: .alive(incarnation: SWIM.Incarnation(i + 1)), shouldSucceed: true)
        }

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(6)
    }

    func test_mark_shouldNotApplyOlderStatus() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .suspect(incarnation: 1))
        state.incrementProtocolPeriod()

        try validateMark(state: state, member: probe.ref, status: .suspect(incarnation: 0), shouldSucceed: false)
        try validateMark(state: state, member: probe.ref, status: .alive(incarnation: 1), shouldSucceed: false)

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_mark_shouldApplyDead() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .suspect(incarnation: 1))
        state.incrementProtocolPeriod()

        try validateMark(state: state, member: probe.ref, status: .dead, shouldSucceed: true)

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(1)
    }

    func test_mark_shouldNotApplyAnyStatusIfAlreadyDead() throws {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .dead)
        state.incrementProtocolPeriod()

        try validateMark(state: state, member: probe.ref, status: .alive(incarnation: 99), shouldSucceed: false)
        try validateMark(state: state, member: probe.ref, status: .suspect(incarnation: 99), shouldSucceed: false)
        try validateMark(state: state, member: probe.ref, status: .dead, shouldSucceed: false)

        state.membershipInfo(for: probe.ref)!.protocolPeriod.shouldEqual(0)
    }

    func test_incrementIncarnation_shouldIncrementTheIncarnationNumberByOne() {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        for i in 0..<10 {
            state.incarnation.shouldEqual(SWIM.Incarnation(i))
            state.incrementIncarnation()
        }
    }

    func test_incrementProtocolPeriod_shouldIncrementTheProtocolPeriodNumberByOne() {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        for i in 0..<10 {
            state.protocolPeriod.shouldEqual(i)
            state.incrementProtocolPeriod()
        }
    }

    func test_members_shouldContainAllAddedMembers() {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        let p1 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = testKit.spawnTestProbe(expecting: SWIM.Message.self)

        state.addMember(p1.ref, status: .alive(incarnation: 0))
        state.addMember(p2.ref, status: .alive(incarnation: 0))
        state.addMember(p3.ref, status: .alive(incarnation: 0))

        state.isMember(p1.ref).shouldBeTrue()
        state.isMember(p2.ref).shouldBeTrue()
        state.isMember(p3.ref).shouldBeTrue()
    }

    func test_nextMemberToPing_shouldReturnEachMemberOnceBeforeRepeating() throws {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        var members: Set<ActorRef<SWIM.Message>> = []
        for _ in 0...10 {
            let p = testKit.spawnTestProbe(expecting: SWIM.Message.self)
            members.insert(p.ref)
            state.addMember(p.ref, status: .alive(incarnation: 0))
        }

        var seenMembers: Set<ActorRef<SWIM.Message>> = []
        for _ in 0...10 {
            guard let member = state.nextMemberToPing() else {
                throw testKit.fail("Could not fetch member to ping")
            }

            seenMembers.insert(member).inserted.shouldBeTrue()
        }

        for _ in 0...10 {
            guard let member = state.nextMemberToPing() else {
                throw testKit.fail("Could not fetch member to ping")
            }

            seenMembers.insert(member).inserted.shouldBeFalse()
        }
    }

    func test_addMember_shouldNotAddLocalNodeForPinging() {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: probe.path, settings: .default)

        state.addMember(probe.ref, status: .alive(incarnation: 0))
        state.isMember(probe.ref).shouldBeTrue()

        state.nextMemberToPing().shouldBeNil()
    }

    func test_randomMembersToPing() {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)
        let p1 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = testKit.spawnTestProbe(expecting: SWIM.Message.self)

        state.addMember(p1.ref, status: .alive(incarnation: 0))
        state.addMember(p2.ref, status: .alive(incarnation: 0))
        state.addMember(p3.ref, status: .alive(incarnation: 0))

        let membersToPing = state.randomMembersToRequestPing(target: probe.ref)

        membersToPing.count.shouldEqual(3)

        membersToPing.shouldContain(p1.ref)
        membersToPing.shouldContain(p2.ref)
        membersToPing.shouldContain(p3.ref)
    }

    func test_membershipStatus_shouldReturnTheLastAssignedStatusForAMember() {
        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        state.addMember(probe.ref, status: .alive(incarnation: 0))
        state.membershipStatus(of: probe.ref)?.shouldEqual(.alive(incarnation: 0))

        _ = state.mark(probe.ref, as: .suspect(incarnation: 99))
        state.membershipStatus(of: probe.ref)?.shouldEqual(.suspect(incarnation: 99))
    }

    func test_suspects_shouldReturnOnlySuspectedNodes() {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)

        let p1 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = testKit.spawnTestProbe(expecting: SWIM.Message.self)

        state.addMember(p1.ref, status: .alive(incarnation: 0))
        state.addMember(p2.ref, status: .alive(incarnation: 0))
        state.addMember(p3.ref, status: .alive(incarnation: 0))

        validateSuspects(state: state, expected: [])

        _ = state.mark(p1.ref, as: .suspect(incarnation: 0))
        validateSuspects(state: state, expected: [p1.ref])

        _ = state.mark(p3.ref, as: .suspect(incarnation: 0))
        validateSuspects(state: state, expected: [p1.ref, p3.ref])

        _ = state.mark(p2.ref, as: .suspect(incarnation: 0))
        _ = state.mark(p1.ref, as: .alive(incarnation: 1))
        validateSuspects(state: state, expected: [p2.ref, p3.ref])
    }

    func test_createGossipPayload_shouldReturnNoneIfNothingToGossip() throws {
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: .default)
        try validateGossip(state: state, expected: [])
    }

    func test_createGossipPayload_shouldReturnEachEntryOnlyTheConfiguredNumberOfTimes() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: settings)

        let p1 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p2 = testKit.spawnTestProbe(expecting: SWIM.Message.self)
        let p3 = testKit.spawnTestProbe(expecting: SWIM.Message.self)

        state.addMember(p1.ref, status: .alive(incarnation: 0))
        try validateGossip(state: state, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0))])

        state.addMember(p2.ref, status: .suspect(incarnation: 1))
        try validateGossip(state: state, expected: [.init(ref: p1.ref, status: .alive(incarnation: 0)), .init(ref: p2.ref, status: .suspect(incarnation: 1))])

        state.addMember(p3.ref, status: .dead)
        try validateGossip(state: state, expected: [.init(ref: p2.ref, status: .suspect(incarnation: 1)), .init(ref: p3.ref, status: .dead)])
        try validateGossip(state: state, expected: [.init(ref: p3.ref, status: .dead)])
        try validateGossip(state: state, expected: [])
    }

    func test_createGossipPayload_shouldResetCounterWhenStatusChanged() throws {
        var settings: SWIMSettings = .default
        settings.gossip.maxGossipCountPerMessage = 2
        let state = SWIMMembershipShell.State(localShellPath: localShellPath, settings: settings)

        let probe = testKit.spawnTestProbe(expecting: SWIM.Message.self)

        state.addMember(probe.ref, status: .alive(incarnation: 0))
        try validateGossip(state: state, expected: [.init(ref: probe.ref, status: .alive(incarnation: 0))])

        _ = state.mark(probe.ref, as: .suspect(incarnation: 0))
        try validateGossip(state: state, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0))])
        try validateGossip(state: state, expected: [.init(ref: probe.ref, status: .suspect(incarnation: 0))])
        try validateGossip(state: state, expected: [])
    }

    // TODO: add tests for `createGossipPayload`

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    func validateMark(state: SWIMMembershipShell.State, member: ActorRef<SWIM.Message>, status: SWIM.Status, shouldSucceed: Bool, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let markResult = state.mark(member, as: status)

        if shouldSucceed {
            guard case .applied = markResult else {
                throw self.testKit.fail("Expected `.applied`, got `\(markResult)`", file: file, line: line, column: column)
            }
        } else {
            guard case .ignoredDueToOlderStatus(_) = markResult else {
                throw self.testKit.fail("Expected `.ignoredDueToOlderStatus`, got `\(markResult)`", file: file, line: line, column: column)
            }
        }
    }

    func validateSuspects(state: SWIMMembershipShell.State, expected: Set<ActorRef<SWIM.Message>>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        Set(state.suspects.keys).shouldEqual(expected, file: file, line: line, column: column)
    }

    func validateGossip(state: SWIMMembershipShell.State, expected: Set<SWIM.Member>, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        let payload = state.makeGossipPayload()
        if expected.isEmpty {
            guard case SWIM.Payload.none = payload else {
                throw testKit.fail("Expected `.none`, but got `\(payload)`", file: file, line: line, column: column)
            }
        } else {
            guard case SWIM.Payload.membership(let members) = payload else {
                throw testKit.fail("Expected `.membership`, but got `\(payload)`", file: file, line: line, column: column)
            }

            Set(members).shouldEqual(expected, file: file, line: line, column: column)
        }
    }
}
