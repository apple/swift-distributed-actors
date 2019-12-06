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
import Foundation
import NIOSSL
import XCTest

final class ClusterLeaderActionsTests: ClusteredNodesTestBase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: leader decision: .joining -> .up

    func test_singleLeader() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 1)
            }

            let p = self.testKit(first).spawnTestProbe(expecting: ClusterEvent.self)

            _ = try first.spawn("selfishSingleLeader", Behavior<ClusterEvent>.setup { context in
                context.system.cluster.events.subscribe(context.myself)

                return .receiveMessage { event in
                    switch event {
                    case .leadershipChange:
                        p.tell(event)
                        return .same
                    default:
                        return .same
                    }
                }

            })

            switch try p.expectMessage() {
            case .leadershipChange(let change):
                guard let leader = change.newLeader else {
                    throw self.testKit(first).fail("Expected \(first.cluster.node) to be leader")
                }
                leader.node.shouldEqual(first.cluster.node)
            default:
                throw self.testKit(first).fail("Expected leader change event")
            }
        }
    }

    func test_joining_to_up_decisionByLeader() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)
            }

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)

            try assertAssociated(first, withAtLeast: second.cluster.node)
            try assertAssociated(second, withAtLeast: third.cluster.node)
            try assertAssociated(first, withAtLeast: third.cluster.node)

            try self.testKit(first).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: first, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: first, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: first, node: third.cluster.node, is: .up)
            }

            try self.testKit(second).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: second, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: second, node: third.cluster.node, is: .up)
            }

            try self.testKit(third).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: third, node: first.cluster.node, is: .up)
                try self.assertMemberStatus(on: third, node: second.cluster.node, is: .up)
                try self.assertMemberStatus(on: third, node: third.cluster.node, is: .up)
            }
        }
    }

    func test_joining_to_up_earlyYetStillLettingAllNodesKnowAboutLatestMembershipStatus() throws {
        try shouldNotThrow {
            // This showcases a racy situation, where we allow a leader elected when at least 2 nodes joined
            // yet we actually join 3 nodes -- meaning that the joining up is _slightly_ racy:
            // - maybe nodes 1 and 2 join each other first and 1 starts upping
            // - maybe nodes 2 and 3 join each other and 2 starts upping
            // - and at the same time, maybe while 1 and 2 have started joining, 2 and 3 already joined, and 2 issued up for itself and 3
            //
            // All this is _fine_. The cluster leader is such that under whichever rules we allowed it to be elected
            // it shall perform its duties. This tests however quickly shows that lack of letting the "third" node,
            // via gossip or some other way about the ->up of other nodes once it joins the "others", it'd be stuck waiting for
            // the ->up forever.
            //
            // In other words, this test exercises that there must be _some_ (gossip, or similar "push" membership once a new member joins),
            // to a new member.
            //
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }

            let fourth = self.setUpNode("fourth") { settings in
                settings.cluster.autoLeaderElection = .none // even without election running, it will be notified by things by the others
            }

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)
            try self.ensureNodes(.up, within: .seconds(10), systems: first, second, third)

            // Even the fourth node now could join and be notified about all the existing up members.
            // It does not even have to run any leadership election -- there are leaders in the cluster.
            //
            // We only join one arbitrary node, we will be notified about all nodes:
            fourth.cluster.join(node: third.cluster.node.node)

            try self.ensureNodes(.up, within: .seconds(10), systems: first, second, third, fourth)
        }
    }

    func test_ensureAllSubscribersGetMovingUpEvents() throws {
        try shouldNotThrow {
            // it shall perform its duties. This tests however quickly shows that lack of letting the "third" node,
            // via gossip or some other way about the ->up of other nodes once it joins the "others", it'd be stuck waiting for
            // the ->up forever.
            //
            // In other words, this test exercises that there must be _some_ (gossip, or similar "push" membership once a new member joins),
            // to a new member.
            //
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }
            let p1 = self.testKit(first).spawnTestProbe(expecting: ClusterEvent.self)
            first.cluster.events.subscribe(p1.ref)

            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }
            let p2 = self.testKit(second).spawnTestProbe(expecting: ClusterEvent.self)
            second.cluster.events.subscribe(p2.ref)

            first.cluster.join(node: second.cluster.node.node)

            // this ensures that the membership, as seen in ClusterShell converged on all members being up
            try self.ensureNodes(.up, systems: first, second)

            // the following tests confirm that the manually subscribed actors, got all the events they expected

            // FIXME: notice the joining->joining and up->up events; they do not impact correctness, but we want to fix them; this is mostly due to how we gossip Member() rather than a change to member right now.

            // on the leader node, the other node noticed as up:
            let eventsOnFirstSub = try p1.expectMessages(count: 6)
            eventsOnFirstSub.shouldContain(.snapshot(.empty))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: .joining, toStatus: .joining))) // FIXME: we have to change how we signal changes
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: second.cluster.node, fromStatus: nil, toStatus: .joining)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: .joining, toStatus: .up)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: second.cluster.node, fromStatus: .joining, toStatus: .up)))
            eventsOnFirstSub.shouldContain(.leadershipChange(.init(oldLeader: nil, newLeader: .init(node: first.cluster.node, status: .joining))))

            // on non-leader node
            let eventsOnSecondSub = try p2.expectMessages(count: 6)
            eventsOnSecondSub.shouldContain(.snapshot(.empty))
            eventsOnSecondSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: nil, toStatus: .joining)))
            eventsOnSecondSub.shouldContain(.membershipChange(.init(node: second.cluster.node, fromStatus: .joining, toStatus: .joining)))
            eventsOnSecondSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: .up, toStatus: .up))) // FIXME: by doing a real gossip rather then sending "the member" this will be fixed
            eventsOnSecondSub.shouldContain(.membershipChange(.init(node: second.cluster.node, fromStatus: .up, toStatus: .up))) // FIXME: by doing a real gossip rather then sending "the member" this will be fixed
            eventsOnSecondSub.shouldContain(.leadershipChange(.init(oldLeader: nil, newLeader: .init(node: first.cluster.node, status: .joining))))
        }
    }
}
