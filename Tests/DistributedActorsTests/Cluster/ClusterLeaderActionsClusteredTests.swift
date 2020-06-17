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

final class ClusterLeaderActionsClusteredTests: ClusteredActorSystemsXCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: leader decision: .joining -> .up

    func test_singleLeader() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
            }

            let p = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)

            _ = try first.spawn(
                "selfishSingleLeader",
                Behavior<Cluster.Event>.setup { context in
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
                }
            )

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
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
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
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            }
            let third = self.setUpNode("third") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            }

            let fourth = self.setUpNode("fourth") { settings in
                settings.cluster.autoLeaderElection = .none // even without election running, it will be notified by things by the others
            }

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)
            try self.ensureNodes(.up, within: .seconds(10), nodes: first.cluster.node, second.cluster.node, third.cluster.node)

            // Even the fourth node now could join and be notified about all the existing up members.
            // It does not even have to run any leadership election -- there are leaders in the cluster.
            //
            // We only join one arbitrary node, we will be notified about all nodes:
            fourth.cluster.join(node: third.cluster.node.node)

            try self.ensureNodes(.up, within: .seconds(10), nodes: first.cluster.node, second.cluster.node, third.cluster.node, fourth.cluster.node)
        }
    }

    func test_up_ensureAllSubscribersGetMovingUpEvents() throws {
        try shouldNotThrow {
            // it shall perform its duties. This tests however quickly shows that lack of letting the "third" node,
            // via gossip or some other way about the ->up of other nodes once it joins the "others", it'd be stuck waiting for
            // the ->up forever.
            //
            // In other words, this test exercises that there must be _some_ (gossip, or similar "push" membership once a new member joins),
            // to a new member.
            //
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            }

            let p1 = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)
            first.cluster.events.subscribe(p1.ref)
            let p2 = self.testKit(second).spawnTestProbe(expecting: Cluster.Event.self)
            second.cluster.events.subscribe(p2.ref)

            first.cluster.join(node: second.cluster.node.node)

            // this ensures that the membership, as seen in ClusterShell converged on all members being up
            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node)

            // the following tests confirm that the manually subscribed actors, got all the events they expected
            func assertExpectedClusterEvents(events: [Cluster.Event], probe: ActorTestProbe<Cluster.Event>) throws { // the specific type of snapshot we get is slightly racy: it could be .empty or contain already the node itself
                guard case .some(Cluster.Event.snapshot) = events.first else {
                    throw probe.error("First event always expected to be .snapshot, was: \(optional: events.first)")
                }

                // both nodes moved up
                events.filter { event in
                    switch event {
                    case .membershipChange(let change) where change.isUp:
                        return true
                    default:
                        return false
                    }
                }.count.shouldEqual(2) // both nodes moved to up

                // the leader is the right node
                events.shouldContain(.leadershipChange(Cluster.LeadershipChange(oldLeader: nil, newLeader: .init(node: first.cluster.node, status: .joining))!)) // !-safe, since new/old leader known to be different
            }

            // collect all events until we see leadership change; we should already have seen members become up then
            let eventsOnFirstSub = try collectUntilAllMembers(p1, status: .up)
            try assertExpectedClusterEvents(events: eventsOnFirstSub, probe: p1)

            // on non-leader node
            let eventsOnSecondSub = try collectUntilAllMembers(p2, status: .up)
            try assertExpectedClusterEvents(events: eventsOnSecondSub, probe: p2)
        }
    }

    private func collectUntilAllMembers(_ probe: ActorTestProbe<Cluster.Event>, status: Cluster.MemberStatus) throws -> [Cluster.Event] {
        pinfo("Cluster.Events on \(probe)")
        var events: [Cluster.Event] = []
        var membership = Cluster.Membership.empty

        var found = false
        while events.count < 12, !found {
            let event = try probe.expectMessage()
            pinfo("Captured event: \(event)")
            guard !events.contains(event) else {
                throw self._testKits.first!.fail("Received DUPLICATE cluster event: \(event), while already received: \(lineByLine: events). Duplicate events are illegal, this is a bug.")
            }
            try membership.apply(event: event)
            events.append(event)

            found = membership.count > 0 && membership.members(atLeast: .joining).allSatisfy { $0.status == status }
        }
        return events
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: .down -> removal

    func test_down_to_removed_ensureRemovalHappensWhenAllHaveSeenDown() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(300)))
            }
            let p1 = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)
            first.cluster.events.subscribe(p1.ref)

            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(300)))
            }
            let p2 = self.testKit(second).spawnTestProbe(expecting: Cluster.Event.self)
            second.cluster.events.subscribe(p2.ref)

            let third = self.setUpNode("third") { settings in
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(300)))
            }
            let p3 = self.testKit(third).spawnTestProbe(expecting: Cluster.Event.self)
            third.cluster.events.subscribe(p3.ref)

            try self.joinNodes(node: first, with: second)
            try self.joinNodes(node: second, with: third)
            try self.joinNodes(node: first, with: third)

            let secondNode = second.cluster.node
            try self.ensureNodes(.up, nodes: first.cluster.node, secondNode, third.cluster.node)

            first.cluster.down(node: secondNode.node)

            // other nodes have observed it down
            try self.ensureNodes(.down, on: first, nodes: secondNode)
            try self.ensureNodes(.down, on: third, nodes: secondNode)

            // on the leader node, the other node noticed as up:
            var eventsOnFirstSub: [Cluster.Event] = []
            var downFound = false
            while eventsOnFirstSub.count < 12, !downFound {
                let event = try p1.expectMessage()
                pinfo("Captured event: \(event)")
                eventsOnFirstSub.append(event)

                switch event {
                case .membershipChange(let change) where change.toStatus.isDown:
                    downFound = true
                default:
                    ()
                }
            }

            eventsOnFirstSub.shouldContain(.snapshot(.empty))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: nil, toStatus: .joining)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: secondNode, fromStatus: nil, toStatus: .joining)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: first.cluster.node, fromStatus: .joining, toStatus: .up)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: secondNode, fromStatus: .joining, toStatus: .up)))
            eventsOnFirstSub.shouldContain(.leadershipChange(Cluster.LeadershipChange(oldLeader: nil, newLeader: .init(node: first.cluster.node, status: .joining))!)) // !-safe, since new/old leader known to be different
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: third.cluster.node, fromStatus: nil, toStatus: .joining)))
            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: third.cluster.node, fromStatus: .joining, toStatus: .up)))

            eventsOnFirstSub.shouldContain(.membershipChange(.init(node: secondNode, fromStatus: .up, toStatus: .down)))

            try self.testKit(first).eventually(within: .seconds(3)) {
                let p1s = self.testKit(first).spawnTestProbe(expecting: Cluster.Membership.self)
                first.cluster.ref.tell(.query(.currentMembership(p1s.ref)))
            }
        }
    }

    func test_ensureDownAndRemovalSpreadsToAllMembers() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.swim.probeInterval = .milliseconds(300)
                settings.cluster.swim.pingTimeout = .milliseconds(100)
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(200)))
            }
            let p1 = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)
            first.cluster.events.subscribe(p1.ref)

            let second = self.setUpNode("second") { settings in
                settings.cluster.swim.probeInterval = .milliseconds(300)
                settings.cluster.swim.pingTimeout = .milliseconds(100)
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(200)))
            }
            let p2 = self.testKit(second).spawnTestProbe(expecting: Cluster.Event.self)
            second.cluster.events.subscribe(p2.ref)

            let third = self.setUpNode("third") { settings in
                settings.cluster.swim.probeInterval = .milliseconds(300)
                settings.cluster.swim.pingTimeout = .milliseconds(100)
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
                settings.cluster.downingStrategy = .timeout(.init(downUnreachableMembersAfter: .milliseconds(200)))
            }
            let p3 = self.testKit(third).spawnTestProbe(expecting: Cluster.Event.self)
            third.cluster.events.subscribe(p3.ref)

            try self.joinNodes(node: first, with: second)
            try self.joinNodes(node: second, with: third)
            try self.joinNodes(node: first, with: third)

            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node)

            // crash the second node
            second.shutdown()

            // other nodes have observed it down
            try self.ensureNodes(.down, on: first, within: .seconds(15), nodes: second.cluster.node)
            try self.ensureNodes(.down, on: third, within: .seconds(15), nodes: second.cluster.node)

            // on the leader node, the other node noticed as up:
            let testKit = self.testKit(first)
            try testKit.eventually(within: .seconds(20)) {
                let event: Cluster.Event? = try p1.maybeExpectMessage()
                switch event {
                case .membershipChange(.init(node: second.cluster.node, fromStatus: .up, toStatus: .down)): ()
                case let other: throw testKit.error("Expected `second` [     up] -> [  .down], on first node, was: \(other, orElse: "nil")")
                }
            }
            try testKit.eventually(within: .seconds(20)) {
                let event: Cluster.Event? = try p1.maybeExpectMessage()
                switch event {
                case .membershipChange(.init(node: second.cluster.node, fromStatus: .down, toStatus: .removed)): ()
                case let other: throw testKit.error("Expected `second` [     up] -> [  .down], on first node, was: \(other, orElse: "nil")")
                }
            }
        }
    }
}
