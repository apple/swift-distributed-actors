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
import DistributedCluster
import Logging
import NIO
import XCTest

final class CustomLeadershipClusteredTests: ClusteredActorSystemsXCTestCase {

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Custom Actor based leadership

    distributed actor AppointLeaderManually: CustomStringConvertible {
        var membership: Cluster.Membership

        @ActorID.Metadata(\.receptionID)
        var receptionID: String

        lazy var log = {
            var l = actorSystem.settings.logging.baseLogger
            l[metadataKey: "actor/id"] = "\(Self.self)"
            return l
        }()

        /// We can manually appoint a leader
        var appointedLeader: Cluster.Node? = nil

        init(_ actorSystem: ClusterSystem) async {
            self.actorSystem = actorSystem
            self.membership = .empty

            self.receptionID = "leader-election"
            await actorSystem.receptionist.checkIn(self)
        }

        // !! DO NOT USE FOR REAL; This isn't a coherent election algorithm !!
        // We just inform all other peers about our decision; it works since in our test we only ever make one decision.
        // This is mean to illustrate the use of receptionist during start of the cluster, before nodes have become up,
        // or we even have had a chance to assign an initial leader.
        //
        // In other words:
        // - use receptionist to discover actors who will perform an election
        // - run election algorithm
        // - each node
        //
        // TODO: Instead, implement a Bully algorithm as a showcase.
        distributed public func appointLeader(member: Cluster.Member) async throws {
            log.info("Appointing cluster leader manually: \(member)", metadata: [
                "membership/newLeader": "\(member)",
            ])

            guard try self.membership.applyLeadershipChange(to: member) != nil else {
                return // the change was ineffective, no need to keep churning on it
            }
            actorSystem.cluster.assumeLeader(member)

            // This is pretty naive, we should do better than that, designate a task for informing others about our decision.
            Task {
                let key = DistributedReception.Key(self)! // !-safe, we always have a receptionID set on this actor
                log.notice("Look for other leadership actors: \(key)")
                for await peer in await actorSystem.receptionist.listing(of: key) {
                    guard peer != self else {
                        continue
                    }

                    // This is rather naive, but we do this to break a deadlock cycle.
                    do {
                        log.notice("Inform \(peer.id) about leadership change to: \(member)")
                        try await peer.appointLeader(member: member)
                    } catch {
                        log.warning("Failed to appoint leader on peer: \(peer)", metadata: [
                            "peer": "\(peer)",
                            "leadership/appointed": "\(member)",
                            "error": "\(error)",
                        ])
                    }
                }
            }
        }

        nonisolated var description: String {
            "AppointLeaderManually(\(self.id.detailedDescription))"
        }
    }

    func test_CustomLeadership_appointLeaderManually() async throws {
        let first = await self.setUpNode("first") { settings in
            settings.autoLeaderElection = .none
        }
        let second = await self.setUpNode("second") { settings in
            settings.autoLeaderElection = .none
        }
        let third = await self.setUpNode("third") { settings in
            settings.autoLeaderElection = .none
        }

        try await self.joinNodes(node: first, with: second)
        try await self.joinNodes(node: second, with: third)
        try await self.joinNodes(node: first, with: second)

        try await self.ensureNodes(.joining, nodes: first.cluster.node, second.cluster.node, third.cluster.node)

        // Generally, you'd start the "leadership actors" on all nodes,
        // and they somehow figure out who should be doing the assigning.
        //
        // These are ofc allowed to be distributed actors and talk to each-other as well.
        let firstLeadership = await AppointLeaderManually(first)
        let secondLeadership = await AppointLeaderManually(second)
        let thirdLeadership = await AppointLeaderManually(third)

        // let's say the first one gets to decide:
        try await firstLeadership.appointLeader(member: second.cluster.member)

        let leaderSeenByFirst = try await first.cluster.waitForLeader(atLeast: .joining, within: .seconds(20))
        let leaderSeenBySecond = try await second.cluster.waitForLeader(atLeast: .joining, within: .seconds(20))
        let leaderSeenByThird = try await third.cluster.waitForLeader(atLeast: .joining, within: .seconds(20))

        let expectedLeader = await second.cluster.member
        leaderSeenByFirst.shouldEqual(expectedLeader)
        leaderSeenBySecond.shouldEqual(expectedLeader)
        leaderSeenByThird.shouldEqual(expectedLeader)

//        try await second.cluster.waitToBecomeLeader() // we're expected to notice we have become the leader right away
    }



}
