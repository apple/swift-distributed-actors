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

final class TimeoutBasedDowningInstanceTests: XCTestCase {
    var instance: TimeoutBasedDowningStrategy!

    let selfNode = UniqueNode(node: Node(systemName: "Test", host: "localhost", port: 8888), nid: .random())
    lazy var selfMember = Member(node: self.selfNode, status: .up)

    let otherNode = UniqueNode(node: Node(systemName: "Test", host: "localhost", port: 9999), nid: .random())
    lazy var otherMember = Member(node: self.otherNode, status: .up)

    let nonMemberNode = UniqueNode(node: Node(systemName: "Test", host: "localhost", port: 1111), nid: .random())
    lazy var nonMember = Member(node: self.nonMemberNode, status: .up)

    override func setUp() {
        self.instance = TimeoutBasedDowningStrategy(.default, selfNode: self.selfNode)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: onLeaderChange

    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsSelfAddress_shouldBecomeLeader() throws {
        self.instance.isLeader.shouldBeFalse()
        let directive = try self.instance.onLeaderChange(to: self.selfMember)
        // when no nodes are pending to be downed, the directive should be `.none`
        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }
        self.instance.isLeader.shouldBeTrue()
    }

    // FIXME: has to be changed a bit when downing moved to subscribing to MembershipChange events
    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsOtherAddress_shouldNotBecomeLeader() throws {
        try shouldNotThrow {
            self.instance.isLeader.shouldBeFalse()

            self.instance.membership.join(self.otherNode)
            let directive = try self.instance.onLeaderChange(to: self.otherMember)
            // we the node does not become the leader, the directive should be `.none`
            guard case .none = directive else {
                throw TestError("Expected directive to be .none")
            }
            self.instance.isLeader.shouldBeFalse()
        }
    }

    func test_onLeaderChange_whenLeaderAndNewLeaderIsOtherAddress_shouldLoseLeadership() throws {
        try shouldNotThrow {
            self.instance.membership.join(self.selfNode)
            self.instance.membership.join(self.otherNode)

            try self.instance.onLeaderChange(to: self.selfMember)
            self.instance.isLeader.shouldBeTrue()
            let directive = try self.instance.onLeaderChange(to: self.otherMember)
            // when losing leadership, the directive should be `.none`
            guard case .none = directive else {
                throw TestError("Expected directive to be .none")
            }
            self.instance.isLeader.shouldBeFalse()
        }
    }

    func test_onLeaderChange_whenNonMemberSelectedAsLeader_shouldThrow() throws {
        let err = shouldThrow {
            try self.instance.membership.applyLeadershipChange(to: self.nonMember)
        }
        "\(err)".shouldStartWith(prefix: "nonMemberLeaderSelected")
    }

    func test_onLeaderChange_whenLeaderAndNewLeaderIsSelfAddress_shouldStayLeader() throws {
        try self.instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
        _ = try self.instance.onLeaderChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
    }

    func test_onLeaderChange_whenLeaderAndNoNewLeaderIsElected_shouldLoseLeadership() throws {
        try self.instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
        _ = try self.instance.onLeaderChange(to: nil)
        self.instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenNotLeaderAndNoNewLeaderIsElected_shouldNotBecomeLeader() throws {
        self.instance.isLeader.shouldBeFalse()
        _ = try self.instance.onLeaderChange(to: nil)
        self.instance.isLeader.shouldBeFalse()
    }

    func test_onLeaderChange_whenBecomingLeaderAndNodesPendingToBeDowned_shouldReturnMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = try self.instance.onLeaderChange(to: self.selfMember)
        guard case .markAsDown(let addresses) = directive else {
            throw Boom()
        }
        addresses.count.shouldEqual(1)
        addresses.shouldContain(member.node)
        self.instance.isLeader.shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onTimeout

    func test_onTimeout_whenNotCurrentlyLeader_shouldInsertMemberAddressIntoMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        instance.isLeader.shouldBeFalse()
        self.instance._unreachable.insert(member.node)
        let directive = self.instance.onTimeout(member)

        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }

        self.instance._markAsDown.shouldContain(member.node)
    }

    func test_onTimeout_whenCurrentlyLeader_shouldReturnMarkAsDown() throws {
        let member = Member(node: otherNode, status: .up)
        try instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance._unreachable.insert(member.node)
        let directive = self.instance.onTimeout(member)

        guard case .markAsDown(let address) = directive else {
            throw TestError("Expected directive to be .markAsDown")
        }

        address.shouldEqual(member.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberRemoved

    func test_onMemberRemoved_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Member(node: otherNode, status: .up)
        instance._unreachable.insert(member.node)
        let directive = self.instance.onMemberRemoved(member)

        guard case .cancelTimer = directive else {
            throw TestError("Expected directive to be .cancelTimer")
        }
    }

    func test_onMemberRemoved_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = self.instance.onMemberRemoved(member)

        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }
    }

    func test_onMemberRemoved_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        let directive = self.instance.onMemberRemoved(member)

        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberReachable

    func test_onMemberReachable_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Member(node: otherNode, status: .up)
        instance._unreachable.insert(member.node)
        let directive = self.instance.onMemberReachable(member)

        guard case .cancelTimer = directive else {
            throw TestError("Expected directive to be .cancelTimer")
        }
    }

    func test_onMemberReachable_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        instance._markAsDown.insert(member.node)
        let directive = self.instance.onMemberReachable(member)

        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }
    }

    func test_onMemberReachable_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Member(node: otherNode, status: .up)
        let directive = self.instance.onMemberReachable(member)

        guard case .none = directive else {
            throw TestError("Expected directive to be .none")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberUnreachable

    func test_onMemberUnreachable_shouldAddAddressOfMemberToUnreachableSet() throws {
        let member = Member(node: otherNode, status: .up)
        guard case .startTimer = self.instance.onMemberUnreachable(member) else {
            throw TestError("Expected directive to be .startTimer")
        }
        self.instance._unreachable.shouldContain(member.node)
    }
}
