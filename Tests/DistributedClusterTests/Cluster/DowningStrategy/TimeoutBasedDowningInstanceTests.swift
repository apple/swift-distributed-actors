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

import DistributedActorsTestKit
@testable import DistributedCluster
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
final class TimeoutBasedDowningInstanceTests {
    var instance: TimeoutBasedDowningStrategy!

    let selfNode = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "Test", host: "localhost", port: 8888), nid: .random())
    lazy var selfMember = Cluster.Member(node: self.selfNode, status: .up)

    let otherNode = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "Test", host: "localhost", port: 9999), nid: .random())
    lazy var otherMember = Cluster.Member(node: self.otherNode, status: .up)

    let yetAnotherNode = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "Test", host: "localhost", port: 2222), nid: .random())
    lazy var yetAnotherMember = Cluster.Member(node: self.yetAnotherNode, status: .up)

    let nonMemberNode = Cluster.Node(endpoint: Cluster.Endpoint(systemName: "Test", host: "localhost", port: 1111), nid: .random())
    lazy var nonMember = Cluster.Member(node: self.nonMemberNode, status: .up)

    init() {
        self.instance = TimeoutBasedDowningStrategy(.default, selfNode: self.selfNode)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: onLeaderChange
    @Test
    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsSelfAddress_shouldBecomeLeader() throws {
        self.instance.isLeader.shouldBeFalse()
        let directive = try self.instance.onLeaderChange(to: self.selfMember)
        // when no nodes are pending to be downed, the directive should be `.none`
        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
        self.instance.isLeader.shouldBeTrue()
    }

    // FIXME: has to be changed a bit when downing moved to subscribing to Cluster.MembershipChange events
    @Test
    func test_onLeaderChange_whenNotLeaderAndNewLeaderIsOtherAddress_shouldNotBecomeLeader() throws {
        self.instance.isLeader.shouldBeFalse()

        _ = self.instance.membership.join(self.otherNode)
        let directive = try self.instance.onLeaderChange(to: self.otherMember)
        // we the node does not become the leader, the directive should be `.none`
        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
        self.instance.isLeader.shouldBeFalse()
    }

    @Test
    func test_onLeaderChange_whenLeaderAndNewLeaderIsOtherAddress_shouldLoseLeadership() throws {
        _ = self.instance.membership.join(self.selfNode)
        _ = self.instance.membership.join(self.otherNode)

        _ = try self.instance.onLeaderChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
        let directive = try self.instance.onLeaderChange(to: self.otherMember)
        // when losing leadership, the directive should be `.none`
        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
        self.instance.isLeader.shouldBeFalse()
    }

    @Test
    func test_onLeaderChange_whenLeaderAndNewLeaderIsSelfAddress_shouldStayLeader() throws {
        _ = try self.instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
        _ = try self.instance.onLeaderChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
    }

    @Test
    func test_onLeaderChange_whenLeaderAndNoNewLeaderIsElected_shouldLoseLeadership() throws {
        _ = try self.instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance.isLeader.shouldBeTrue()
        _ = try self.instance.onLeaderChange(to: nil)
        self.instance.isLeader.shouldBeFalse()
    }

    @Test
    func test_onLeaderChange_whenNotLeaderAndNoNewLeaderIsElected_shouldNotBecomeLeader() throws {
        self.instance.isLeader.shouldBeFalse()
        _ = try self.instance.onLeaderChange(to: nil)
        self.instance.isLeader.shouldBeFalse()
    }

    @Test
    func test_onLeaderChange_whenBecomingLeaderAndNodesPendingToBeDowned_shouldReturnMarkAsDown() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance._markAsDown.insert(member)
        let directive = try self.instance.onLeaderChange(to: self.selfMember)
        guard case .markAsDown(let addresses) = directive.underlying else {
            throw Boom()
        }
        addresses.count.shouldEqual(1)
        addresses.shouldContain(member)
        self.instance.isLeader.shouldBeTrue()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onTimeout
    @Test
    func test_onTimeout_whenNotCurrentlyLeader_shouldInsertMemberAddressIntoMarkAsDown() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance.isLeader.shouldBeFalse()
        self.instance._unreachable.insert(member)
        let directive = self.instance.onTimeout(member)

        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }

        self.instance._markAsDown.shouldContain(member)
    }

    @Test
    func test_onTimeout_whenCurrentlyLeader_shouldReturnMarkAsDown() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        _ = try self.instance.membership.applyLeadershipChange(to: self.selfMember)
        self.instance._unreachable.insert(member)
        let directive = self.instance.onTimeout(member)

        guard case .markAsDown(let node) = directive.underlying else {
            throw TestError("Expected directive to be .markAsDown")
        }

        node.shouldEqual([member])
    }

    @Test
    func test_onTimeout_shouldNotRetainAlreadyIssuedAsDownMembers() throws {
        _ = self.instance.membership.join(self.selfNode)
        _ = self.instance.membership.join(self.otherNode)
        _ = self.instance.membership.join(self.yetAnotherNode)

        // we are the leader, if a timeout happens, we should issue .down
        _ = try self.instance.onLeaderChange(to: self.selfMember)

        let unreachableMember = self.otherMember.asUnreachable

        let directive = self.instance.onMemberUnreachable(.init(member: unreachableMember))
        guard case .startTimer = directive.underlying else {
            throw TestError("Expected .startTimer, but got \(directive)")
        }

        let downDecision = self.instance.onTimeout(unreachableMember)
        guard case .markAsDown(let nodesToDown) = downDecision.underlying else {
            throw TestError("Expected .markAsDown, but got \(directive)")
        }

        nodesToDown.shouldEqual([unreachableMember])

        // since we signalled the .down, no need to retain the member as "to be marked down" anymore,
        // if we never cleaned that set it could be technically a memory leak, continuing to accumulate
        // all members that we downed over the lifetime of the cluster.
        self.instance._markAsDown.shouldBeEmpty()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberRemoved
    @Test
    func test_onMemberRemoved_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance._unreachable.insert(member)
        let directive = self.instance.onMemberRemoved(member)

        guard case .cancelTimer = directive.underlying else {
            throw TestError("Expected directive to be .cancelTimer")
        }
    }

    @Test
    func test_onMemberRemoved_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance._markAsDown.insert(member)
        let directive = self.instance.onMemberRemoved(member)

        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
    }

    @Test
    func test_onMemberRemoved_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        let directive = self.instance.onMemberRemoved(member)

        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberReachable
    @Test
    func test_onMemberReachable_whenMemberWasUnreachable_shouldReturnCancelTimer() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance._unreachable.insert(member)
        let directive = self.instance.onMemberReachable(.init(member: member.asUnreachable))

        guard case .cancelTimer = directive.underlying else {
            throw TestError("Expected directive to be .cancelTimer")
        }
    }

    @Test
    func test_onMemberReachable_whenMemberWasMarkAsDown_shouldReturnNone() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        self.instance._markAsDown.insert(member)
        let directive = self.instance.onMemberReachable(.init(member: member.asUnreachable))

        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
    }

    @Test
    func test_onMemberReachable_whenMemberNotKnown_shouldReturnNone() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        let directive = self.instance.onMemberReachable(.init(member: member.asUnreachable))

        guard case .none = directive.underlying else {
            throw TestError("Expected directive to be .none")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: onMemberUnreachable
    @Test
    func test_onMemberUnreachable_shouldAddAddressOfMemberToUnreachableSet() throws {
        let member = Cluster.Member(node: self.otherNode, status: .up)
        guard case .startTimer = self.instance.onMemberUnreachable(.init(member: member.asUnreachable)).underlying else {
            throw TestError("Expected directive to be .startTimer")
        }
        self.instance._unreachable.shouldContain(member.asUnreachable)
    }
}
