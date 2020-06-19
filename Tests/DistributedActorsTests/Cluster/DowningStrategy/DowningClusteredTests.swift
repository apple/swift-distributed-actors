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
final class DowningClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/replicator",
            "/system/replicator/gossip",
            "/system/receptionist",
            "/system/cluster/swim",
        ]
    }

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

    func shared_stoppingNode_shouldPropagateToOtherNodesAsDown(
        stopMethod: NodeStopMethod,
        stopNode: StopNodeSelection,
        _ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil
    ) throws {
        let (first, second) = self.setUpPair { settings in
            settings.cluster.swim.probeInterval = .milliseconds(500)
            modifySettings?(&settings)
        }
        let thirdNeverDownSystem = self.setUpNode("third", modifySettings)

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
        let eventsProbeOther = self.testKit(otherNotDownPairSystem).spawnEventStreamTestProbe(subscribedTo: otherNotDownPairSystem.cluster.events)
        let eventsProbeThird = self.testKit(thirdNeverDownSystem).spawnEventStreamTestProbe(subscribedTo: thirdNeverDownSystem.cluster.events)

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

        func expectedDownMemberEventsFishing(
            on: ActorSystem,
            file: StaticString = #file, line: UInt = #line
        ) -> (Cluster.Event) -> ActorTestProbe<Cluster.Event>.FishingDirective<Cluster.MembershipChange> {
            pinfo("Expecting [\(expectedDownSystem)] to become [.down] on [\(on.cluster.node.node)], method to stop the node [\(stopMethod)]")

            return { event in
                switch event {
                case .membershipChange(let change) where change.node == expectedDownNode && change.isRemoval:
                    pinfo("\(on.cluster.node.node): \(change)", file: file, line: line)
                    return .catchComplete(change)
                case .membershipChange(let change) where change.node == expectedDownNode:
                    pinfo("\(on.cluster.node.node): \(change)", file: file, line: line)
                    return .catchContinue(change)
                case .reachabilityChange(let change) where change.member.node == expectedDownNode:
                    pnote("\(on.cluster.node.node): \(change)", file: file, line: line)
                    return .ignore
                default:
                    pnote("\(on.cluster.node.node): \(event)", file: file, line: line)
                    return .ignore
                }
            }
        }

        // collect all events regarding the expectedDownNode's membership lifecycle
        // (the timeout is fairly large here to tolerate slow CI and variations how the events get propagated, normally they propagate quite quickly)
        let eventsOnOther = try eventsProbeOther.fishFor(Cluster.MembershipChange.self, within: .seconds(30), expectedDownMemberEventsFishing(on: otherNotDownPairSystem))
        eventsOnOther.shouldContain(where: { change in change.toStatus.isDown && (change.fromStatus == .joining || change.fromStatus == .up) })
        eventsOnOther.shouldContain(Cluster.MembershipChange(node: expectedDownNode, fromStatus: .down, toStatus: .removed))

        let eventsOnThird = try eventsProbeThird.fishFor(Cluster.MembershipChange.self, within: .seconds(30), expectedDownMemberEventsFishing(on: thirdNeverDownSystem))
        eventsOnThird.shouldContain(where: { change in change.toStatus.isDown && (change.fromStatus == .joining || change.fromStatus == .up) })
        eventsOnThird.shouldContain(Cluster.MembershipChange(node: expectedDownNode, fromStatus: .down, toStatus: .removed))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: cluster.leave() immediate

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

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: "Mass" Downing

    func test_many_nonLeaders_shouldPropagateToOtherNodes() throws {
        let first = self.setUpNode("node-1")
        var nodes = (2 ... 7).map {
            self.setUpNode("node-\($0)")
        }

        pinfo("Joining \(nodes.count + 1) nodes...")
        let joiningStart = first.metrics.uptimeNanoseconds()

        nodes.forEach {
            first.cluster.join(node: $0.cluster.node.node)
        }
        try self.ensureNodes(.up, within: .seconds(30), nodes: nodes.map {
            $0.cluster.node
        })

        let joiningStop = first.metrics.uptimeNanoseconds()
        pinfo("Joined \(nodes.count + 1) nodes, took: \(TimeAmount.nanoseconds(joiningStop - joiningStart).prettyDescription)")

        let nodesToDown = nodes.prefix(nodes.count / 2)
        nodes.removeFirst(nodes.count / 2)

        pinfo("Downing \(nodes.count / 2) nodes: \(nodesToDown.map { $0.cluster.node })")
        for node in nodesToDown {
            node.shutdown().wait()
        }

        nodes.append(first)
        var probes: [UniqueNode: ActorTestProbe<Cluster.Event>] = [:]
        for remainingNode in nodes {
            probes[remainingNode.cluster.node] = self.testKit(remainingNode).spawnEventStreamTestProbe(subscribedTo: remainingNode.cluster.events)
        }

        func expectedDownMemberEventsFishing(
            on: ActorSystem,
            file: StaticString = #file, line: UInt = #line
        ) -> (Cluster.Event) -> ActorTestProbe<Cluster.Event>.FishingDirective<Cluster.MembershipChange> {
            pinfo("Expecting \(nodesToDown.map { $0.cluster.node.node }) to become [.down] on [\(on.cluster.node.node)]")
            var removalsFound = 0

            return { event in
                switch event {
                case .membershipChange(let change) where change.isRemoval:
                    pinfo("\(on.cluster.node.node): \(change)", file: file, line: line)
                    removalsFound += 1
                    if removalsFound == nodesToDown.count {
                        return .catchComplete(change)
                    } else {
                        return .catchContinue(change)
                    }
                case .membershipChange(let change) where change.isDown:
                    pinfo("\(on.cluster.node.node): \(change)", file: file, line: line)
                    return .catchContinue(change)
                default:
                    return .ignore
                }
            }
        }

        for remainingNode in nodes {
            let probe = probes[remainingNode.cluster.node]!
            let events = try probe.fishFor(Cluster.MembershipChange.self, within: .seconds(60), expectedDownMemberEventsFishing(on: remainingNode))

            events.shouldContain(where: { change in change.toStatus.isDown && (change.fromStatus == .joining || change.fromStatus == .up) })
            for expectedDownNode in nodesToDown {
                events.shouldContain(Cluster.MembershipChange(node: expectedDownNode.cluster.node, fromStatus: .down, toStatus: .removed))
            }
        }
    }
}
