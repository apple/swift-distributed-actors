//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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

// "Get down!"
@Suite(.timeLimit(.minutes(1)), .serialized)
struct DowningClusteredTests {
    let testCase: ClusteredActorSystemsTestCase

    init() throws {
        self.testCase = try ClusteredActorSystemsTestCase()
        self.self.testCase.configureLogCapture = { settings in
            settings.excludeActorPaths = [
                "/system/replicator",
                "/system/replicator/gossip",
                "/system/receptionist",
                "/system/cluster/swim",
            ]
        }
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
        _ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil
    ) async throws {
        let (first, second) = await self.testCase.setUpPair { settings in
            settings.swim.probeInterval = .milliseconds(500)
            modifySettings?(&settings)
        }
        let thirdNeverDownSystem = await self.testCase.setUpNode("third", modifySettings)

        try await self.testCase.joinNodes(node: first, with: second, ensureMembers: .up)
        try await self.testCase.joinNodes(node: thirdNeverDownSystem, with: second, ensureMembers: .up)

        let expectedDownSystem: ClusterSystem
        let otherNotDownPairSystem: ClusterSystem
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
        let eventsProbeOther = await self.testCase.testKit(otherNotDownPairSystem).spawnClusterEventStreamTestProbe()
        let eventsProbeThird = await self.testCase.testKit(thirdNeverDownSystem).spawnClusterEventStreamTestProbe()

        // we cause the stop of the target node as expected
        switch (stopMethod, stopNode) {
        case (.leaveSelfNode, .firstLeader): first.cluster.leave()
        case (.leaveSelfNode, .secondNonLeader): second.cluster.leave()

        case (.downSelf, .firstLeader): first.cluster.down(endpoint: first.cluster.node.endpoint)
        case (.downSelf, .secondNonLeader): second.cluster.down(endpoint: second.cluster.node.endpoint)

        case (.shutdownSelf, .firstLeader): try first.shutdown()
        case (.shutdownSelf, .secondNonLeader): try second.shutdown()

        case (.downFromOtherMember, .firstLeader): second.cluster.down(endpoint: first.cluster.node.endpoint)
        case (.downFromOtherMember, .secondNonLeader): thirdNeverDownSystem.cluster.down(endpoint: second.cluster.node.endpoint)
        }

        func expectedDownMemberEventsFishing(
            on: ClusterSystem,
            file: String = #fileID, line: Int = #line
        ) -> (Cluster.Event) -> ActorTestProbe<Cluster.Event>.FishingDirective<Cluster.MembershipChange> {
            pinfo("Expecting [\(expectedDownSystem)] to become [.down] on [\(on.cluster.node.endpoint)], method to stop the node [\(stopMethod)]")

            return { event in
                switch event {
                case .membershipChange(let change) where change.node == expectedDownNode && change.isRemoval:
                    pinfo("\(on.cluster.node.endpoint): \(change)", file: (file), line: line)
                    return .catchComplete(change)
                case .membershipChange(let change) where change.node == expectedDownNode:
                    pinfo("\(on.cluster.node.endpoint): \(change)", file: (file), line: line)
                    return .catchContinue(change)
                case .reachabilityChange(let change) where change.member.node == expectedDownNode:
                    pnote("\(on.cluster.node.endpoint): \(change)", file: (file), line: line)
                    return .ignore
                default:
                    pnote("\(on.cluster.node.endpoint): \(event)", file: (file), line: line)
                    return .ignore
                }
            }
        }

        // collect all events regarding the expectedDownNode's membership lifecycle
        // - the timeout is fairly large here to tolerate slow CI and variations how the events get propagated, normally they propagate quite quickly
        // - we only check for "did it become down (or was it removed even already), because that's the purpose of these tests
        //   - we have more specific tests which ensure that a down is issued followed by a removal (and here it happens usually as well,
        //     but in order to de-sensitivize the test to timing, we only check for what we actually care about
        // note also that technically we may only "so far" only get a down, and that's okay, the removal would follow soon
        let eventsOnOther = try eventsProbeOther.fishFor(Cluster.MembershipChange.self, within: .seconds(30), expectedDownMemberEventsFishing(on: otherNotDownPairSystem))
        eventsOnOther.shouldContain(where: { change in change.status.isAtLeast(.down) })

        let eventsOnThird = try eventsProbeThird.fishFor(Cluster.MembershipChange.self, within: .seconds(30), expectedDownMemberEventsFishing(on: thirdNeverDownSystem))
        eventsOnThird.shouldContain(where: { change in change.status.isAtLeast(.down) })
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: cluster.leave() immediate
    @Test
    func test_stopLeader_by_leaveSelfNode_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .leaveSelfNode, stopNode: .firstLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    @Test
    func test_stopMember_by_leaveSelfNode_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .leaveSelfNode, stopNode: .secondNonLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: cluster.down(selfNode)
    @Test
    func test_stopLeader_by_downSelf_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downSelf, stopNode: .firstLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    @Test
    func test_stopMember_by_downSelf_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downSelf, stopNode: .secondNonLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by system.shutdown()
    @Test
    func test_stopLeader_by_downByMember_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downFromOtherMember, stopNode: .firstLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    @Test
    func test_stopMember_by_downByMember_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .downFromOtherMember, stopNode: .secondNonLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Stop by: otherSystem.cluster.down(theNode)
    @Test
    func test_stopLeader_by_shutdownSelf_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .shutdownSelf, stopNode: .firstLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    @Test
    func test_stopMember_by_shutdownSelf_shouldPropagateToOtherNodes() async throws {
        try await self.shared_stoppingNode_shouldPropagateToOtherNodesAsDown(stopMethod: .shutdownSelf, stopNode: .secondNonLeader) { settings in
            settings.onDownAction = .gracefulShutdown(delay: .seconds(0))
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            settings.downingStrategy = self.downingStrategy
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: "Mass" Downing
    @Test(.disabled(if: Int.random(in: 10 ... 100) > 0, "SKIPPING FLAKY TEST, REVISIT IT SOON")) // FIXME: https://github.com/apple/swift-distributed-actors/issues/712
    func test_many_nonLeaders_shouldPropagateToOtherNodes() async throws {
        var nodes: [ClusterSystem] = []
        for i in (1 ... 7) {
            nodes[i] = await self.testCase.setUpNode("node-\(i)")
        }
        let first = nodes.first!

        var probes: [Cluster.Node: ActorTestProbe<Cluster.Event>] = [:]
        for remainingNode in nodes {
            probes[remainingNode.cluster.node] = await self.testCase.testKit(remainingNode).spawnClusterEventStreamTestProbe()
        }

        pinfo("Joining \(nodes.count) nodes...")
        let joiningStart = ContinuousClock.Instant.now

        nodes.forEach { first.cluster.join(endpoint: $0.cluster.node.endpoint) }
        try await self.testCase.ensureNodes(.up, within: .seconds(30), nodes: nodes.map(\.cluster.node))

        let joiningStop = ContinuousClock.Instant.now
        pinfo("Joined \(nodes.count) nodes, took: \((joiningStop - joiningStart).prettyDescription)")

        let nodesToDown = nodes.prefix(nodes.count / 2)
        var remainingNodes = nodes
        remainingNodes.removeFirst(nodesToDown.count)

        pinfo("Downing \(nodesToDown.count) nodes: \(nodesToDown.map(\.cluster.node))")
        for node in nodesToDown {
            try! await node.shutdown().wait()
        }

        func expectedDownMemberEventsFishing(
            on: ClusterSystem,
            file: String = #fileID, line: Int = #line
        ) -> (Cluster.Event) -> ActorTestProbe<Cluster.Event>.FishingDirective<Cluster.MembershipChange> {
            pinfo("Expecting \(nodesToDown.map(\.cluster.node.endpoint)) to become [.down] on [\(on.cluster.node.endpoint)]")
            var removalsFound = 0

            return { event in
                switch event {
                case .membershipChange(let change) where change.isRemoval:
                    pinfo("\(on.cluster.node.endpoint): \(change)", file: file, line: line)
                    removalsFound += 1
                    if removalsFound == nodesToDown.count {
                        return .catchComplete(change)
                    } else {
                        return .catchContinue(change)
                    }
                case .membershipChange(let change) where change.isDown:
                    pinfo("\(on.cluster.node.endpoint): \(change)", file: file, line: line)
                    return .catchContinue(change)
                default:
                    return .ignore
                }
            }
        }

        for remainingNode in remainingNodes {
            let probe = probes[remainingNode.cluster.node]!
            let events = try probe.fishFor(Cluster.MembershipChange.self, within: .seconds(60), expectedDownMemberEventsFishing(on: remainingNode))

            events.shouldContain(where: { change in change.status.isDown && (change.previousStatus == .joining || change.previousStatus == .up) })
            for expectedDownNode in nodesToDown {
                events.shouldContain(Cluster.MembershipChange(node: expectedDownNode.cluster.node, previousStatus: .down, toStatus: .removed))
            }
        }
    }
}
