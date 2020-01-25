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

// "Get down!"
final class DowningClusteredTests: ClusteredNodesTestBase {
    enum NodeStopMethod {
        case leaveSelfNode // TODO: eventually this one will be more graceful, ensure others see us leave etc
        case downSelf
        case shutdownSelf
        case downFromOtherMember
    }

    /// Selects which node to stop
    enum StopNodeSelection {
        case firstLeader // the first node is going to be the leader, so testing for downing the leader and a non-leader is recommended.
        case secondNonLeader
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Shared Settings

    private var downingStrategy: DowningStrategySettings {
        .timeout(.init(downUnreachableMembersAfter: .milliseconds(200)))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Downing

    func shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: NodeStopMethod, stopNode: StopNodeSelection, _ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) throws {
        let (first, second) = self.setUpPair(modifySettings)
        let thirdNeverDownSystem = self.setUpNode("third", modifySettings)
        let thirdNeverDownNode = thirdNeverDownSystem.cluster.node

        try self.joinNodes(node: first, with: second, ensureMembers: .up)
        try self.joinNodes(node: thirdNeverDownSystem, with: second, ensureMembers: .up)

        let expectedDownSystem: ActorSystem
        let otherNotDownPairSystem: ActorSystem
        switch stopNode {
        case .firstLeader:
            expectedDownSystem = first
            otherNotDownPairSystem = second
        case .secondNonLeader:
            expectedDownSystem = second
            otherNotDownPairSystem = first
        }

        let expectedDownNode = expectedDownSystem.cluster.node

        // we start cluster event probes early, so they get the events one by one as they happen
        let eventsProbeOther = self.testKit(otherNotDownPairSystem).spawnTestProbe(subscribedTo: otherNotDownPairSystem.cluster.events)
        let eventsProbeThird = self.testKit(thirdNeverDownSystem).spawnTestProbe(subscribedTo: thirdNeverDownSystem.cluster.events)

        pinfo("Expecting [\(expectedDownSystem)] to become [.down], method to stop the node [\(stopMethod)]")

        // we cause the stop of the target node as expected
        switch (stopMethod, stopNode) {
        case (.leaveSelfNode, .firstLeader): first.cluster.leave()
        case (.leaveSelfNode, .secondNonLeader): second.cluster.leave()

        case (.downSelf, .firstLeader): first.cluster.down(node: first.cluster.node.node)
        case (.downSelf, .secondNonLeader): second.cluster.down(node: second.cluster.node.node)

        case (.shutdownSelf, .firstLeader): first.shutdown()
        case (.shutdownSelf, .secondNonLeader): second.shutdown()

        case (.downFromOtherMember, .firstLeader): second.cluster.down(node: first.cluster.node.node)
        case (.downFromOtherMember, .secondNonLeader): thirdNeverDownSystem.cluster.down(node: second.cluster.node.node)
        }

        func expectedDownMemberEventsFishing(on: ActorSystem) -> (Cluster.Event) -> ActorTestProbe<Cluster.Event>.FishingDirective<Cluster.MembershipChange> {
            { event in
                switch event {
                case .membershipChange(let change) where change.node == expectedDownNode && change.isRemoval:
                    pinfo("MembershipChange on \(on.cluster.node.node): \(change)")
                    return .catchComplete(change)
                case .membershipChange(let change) where change.node == expectedDownNode:
                    pinfo("MembershipChange on \(on.cluster.node.node): \(change)")
                    return .catchContinue(change)
                case .reachabilityChange(let change) where change.member.node == expectedDownNode:
                    pnote("ReachabilityChange on \(otherNotDownPairSystem.cluster.node.node) = \(change)")
                    return .ignore
                default:
                    return .ignore
                }
            }
        }

        // collect all events regarding the expectedDownNode's membership lifecycle
        let eventsOnOther = try eventsProbeOther.fishFor(Cluster.MembershipChange.self, within: .seconds(10), expectedDownMemberEventsFishing(on: otherNotDownPairSystem))
        let eventsOnThird = try eventsProbeThird.fishFor(Cluster.MembershipChange.self, within: .seconds(10), expectedDownMemberEventsFishing(on: thirdNeverDownSystem))

        eventsOnOther.shouldContain(where: { change in change.toStatus.isDown && (change.fromStatus == .joining || change.fromStatus == .up) })
        eventsOnOther.shouldContain(Cluster.MembershipChange(node: expectedDownNode, fromStatus: .down, toStatus: .removed))

        eventsOnOther.shouldContain(where: { change in change.toStatus.isDown && (change.fromStatus == .joining || change.fromStatus == .up) })
        eventsOnThird.shouldContain(Cluster.MembershipChange(node: expectedDownNode, fromStatus: .down, toStatus: .removed))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: cluster.leave()

    func test_stopLeader_by_leaveSelfNode_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .leaveSelfNode, stopNode: .firstLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    func test_stopMember_by_leaveSelfNode_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .leaveSelfNode, stopNode: .secondNonLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: cluster.down(selfNode)

    func test_stopLeader_by_downSelf_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downSelf, stopNode: .firstLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    func test_stopMember_by_downSelf_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downSelf, stopNode: .secondNonLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by system.shutdown()

    func test_stopLeader_by_downByMember_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downFromOtherMember, stopNode: .firstLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    func test_stopMember_by_downByMember_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downFromOtherMember, stopNode: .secondNonLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: otherSystem.cluster.down(theNode)

    func test_stopLeader_by_shutdownSelf_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .shutdownSelf, stopNode: .firstLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }

    func test_stopMember_by_shutdownSelf_shouldPropagateToOtherNodes() throws {
        try self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .shutdownSelf, stopNode: .secondNonLeader) { settings in
            settings.cluster.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.cluster.downingStrategy = self.downingStrategy
        }
    }
}
