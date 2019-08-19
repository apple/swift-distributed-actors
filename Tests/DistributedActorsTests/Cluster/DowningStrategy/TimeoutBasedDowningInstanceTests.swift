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
@testable import DistributedActors
import DistributedActorsTestKit

final class TimeoutBasedDowningInstanceTests: XCTestCase {
    var instance: TimeoutBasedDowningStrategy!
    let selfNode = UniqueNode(node: Node(systemName: "Test", host: "localhost", port: 8888), nid: .random())
    let otherNode = UniqueNode(node: Node(systemName: "Test", host: "localhost", port: 9999), nid: .random())

    override func setUp() {
        self.instance = TimeoutBasedDowningStrategy(.default, selfNode: selfNode)
    }

    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsSelfAddress_shouldBecomeLeader() throws {
        instance.isLeader.shouldBeFalse()
        let directive = instance.onLeaderChange(to: selfNode)
        // when no nodes are pending to be downed, the directive should be `.none`
        guard case .none = directive else {
            throw Boom()
        }
        instance.isLeader.shouldBeTrue()
    }

    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsOtherAddress_shouldNotBecomeLeader() throws {
        instance.isLeader.shouldBeFalse()
        let directive = instance.onLeaderChange(to: otherNode)
        // we the node does not become the leader, the directive should be `.none`
        guard case .none = directive else {
            throw Boom()
        }
        instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenLeaderAndNewLeaderIsOtherAddress_shouldLoseLeadership() throws {
        instance._leader = true
        instance.isLeader.shouldBeTrue()
        let directive = instance.onLeaderChange(to: otherNode)
        // when losing leadership, the directive should be `.none`
        guard case .none = directive else {
            throw Boom()
        }
        instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenLeaderAndNewLeaderIsSelfAddress_shouldStayLeader() {
        instance._leader = true
        instance.isLeader.shouldBeTrue()
        _ = instance.onLeaderChange(to: selfNode)
        instance.isLeader.shouldBeTrue()
    }

    func test_onLeaderChange_whenLeaderAndNoNewLeaderIsElected_shouldLoseLeadership() {
        instance._leader = true
        instance.isLeader.shouldBeTrue()
        _ = instance.onLeaderChange(to: nil)
        instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenNotLeaderAndNoNewLeaderIsElected_shouldNotBecomeLeader() {
        instance.isLeader.shouldBeFalse()
        _ = instance.onLeaderChange(to: nil)
        instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenBecomingLeaderAndNodesPendingToBeDowned_shouldReturnMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = instance.onLeaderChange(to: selfNode)
        guard case .markAsDown(let addresses) = directive else {
            throw Boom()
        }
        addresses.count.shouldEqual(1)
        addresses.shouldContain(member.node)
        instance.isLeader.shouldBeTrue()
    }

    func test_onMemberUnreachable_shouldAddAddressOfMemberToUnreachableSet() throws {
        let member = Member(node: otherNode, status: .up)
        guard case .startTimer = instance.onMemberUnreachable(member) else {
            throw Boom()
        }
        instance._unreachable.shouldContain(member.node)
    }

    func test_onTimeout_whenNotCurrentlyLeader_shouldInsertMemberAddressIntoMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        instance.isLeader.shouldBeFalse()
        instance._unreachable.insert(member.node)
        let directive = instance.onTimeout(member)

        guard case .none = directive else {
            throw Boom()
        }

        instance._markAsDown.shouldContain(member.node)
    }

    func test_onTimeout_whenCurrentlyLeader_shouldReturnMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        instance._leader = true
        instance._unreachable.insert(member.node)
        let directive = instance.onTimeout(member)

        guard case .markAsDown(let address) = directive else {
            throw Boom()
        }

        address.shouldEqual(member.node)
    }

    func test_onMemberRemoved_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Member(node: otherNode, status: .up)
        instance._unreachable.insert(member.node)
        let directive = instance.onMemberRemoved(member)

        guard case .cancelTimer = directive else {
            throw Boom()
        }
    }

    func test_onMemberRemoved_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = instance.onMemberRemoved(member)

        guard case .none = directive else {
            throw Boom()
        }
    }

    func test_onMemberRemoved_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        let directive = instance.onMemberRemoved(member)

        guard case .none = directive else {
            throw Boom()
        }
    }

    func test_onMemberReachable_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Member(node: otherNode, status: .up)
        instance._unreachable.insert(member.node)
        let directive = instance.onMemberReachable(member)

        guard case .cancelTimer = directive else {
            throw Boom()
        }
    }

    func test_onMemberReachable_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = instance.onMemberReachable(member)

        guard case .none = directive else {
            throw Boom()
        }
    }

    func test_onMemberReachable_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        let directive = instance.onMemberReachable(member)

        guard case .none = directive else {
            throw Boom()
        }
    }
}
