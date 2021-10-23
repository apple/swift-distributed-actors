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
import NIO
import XCTest

final class ClusterAssociationTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/replicator",
            "/system/cluster/swim",
        ]
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path, accept association

    func test_boundServer_shouldAcceptAssociate() throws {
        let (first, second) = self.setUpPair()

        first.cluster.join(node: second.cluster.uniqueNode.node)

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
    }

    func test_boundServer_shouldAcceptAssociate_raceFromBothNodes() throws {
        let (first, second) = self.setUpPair()
        let n3 = self.setUpNode("node-3")
        let n4 = self.setUpNode("node-4")
        let n5 = self.setUpNode("node-5")
        let n6 = self.setUpNode("node-6")

        first.cluster.join(node: second.cluster.uniqueNode.node)
        second.cluster.join(node: first.cluster.uniqueNode.node)

        n3.cluster.join(node: first.cluster.uniqueNode.node)
        first.cluster.join(node: n3.cluster.uniqueNode.node)

        n4.cluster.join(node: first.cluster.uniqueNode.node)
        first.cluster.join(node: n4.cluster.uniqueNode.node)

        n5.cluster.join(node: first.cluster.uniqueNode.node)
        first.cluster.join(node: n5.cluster.uniqueNode.node)

        n6.cluster.join(node: first.cluster.uniqueNode.node)
        first.cluster.join(node: n6.cluster.uniqueNode.node)

        try assertAssociated(first, withAtLeast: second.cluster.uniqueNode)
        try assertAssociated(second, withAtLeast: first.cluster.uniqueNode)
    }

    func test_handshake_shouldNotifyOnSuccess() throws {
        let (first, second) = self.setUpPair()

        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
    }

    func test_handshake_shouldNotifySuccessWhenAlreadyConnected() throws {
        let (first, second) = self.setUpPair()

        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Joining into existing cluster

    func test_association_sameAddressNodeJoin_shouldOverrideExistingNode() throws {
        let (first, second) = self.setUpPair()

        let secondName = second.cluster.uniqueNode.node.systemName
        let secondPort = second.cluster.uniqueNode.port

        let firstEventsProbe = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)
        let secondEventsProbe = self.testKit(second).spawnTestProbe(expecting: Cluster.Event.self)
        first.cluster.events.subscribe(firstEventsProbe.ref)
        second.cluster.events.subscribe(secondEventsProbe.ref)

        first.cluster.join(node: second.cluster.uniqueNode.node)

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)

        let oldSecond = second
        let shutdown = oldSecond.shutdown() // kill second node
        try shutdown.wait(atMost: .seconds(3))

        let secondReplacement = self.setUpNode(secondName + "-REPLACEMENT") { settings in
            settings.cluster.bindPort = secondPort
        }
        let secondReplacementEventsProbe = self.testKit(secondReplacement).spawnTestProbe(expecting: Cluster.Event.self)
        secondReplacement.cluster.events.subscribe(secondReplacementEventsProbe.ref)
        second.cluster.events.subscribe(secondReplacementEventsProbe.ref)

        // the new replacement node is now going to initiate a handshake with 'first' which knew about the previous
        // instance (oldSecond) on the same node; It should accept this new handshake, and ban the previous node.
        secondReplacement.cluster.join(node: first.cluster.uniqueNode.node)

        // verify we are associated ONLY with the appropriate nodes now;
        try assertAssociated(first, withExactly: [secondReplacement.cluster.uniqueNode])
        try assertAssociated(secondReplacement, withExactly: [first.cluster.uniqueNode])
    }

    func test_association_shouldAllowSendingToSecondReference() throws {
        let (first, second) = self.setUpPair()

        let probeOnSecond = self.testKit(second).spawnTestProbe(expecting: String.self)
        let refOnSecondSystem: _ActorRef<String> = try second.spawn(
            "secondAcquaintance",
            .receiveMessage { message in
                probeOnSecond.tell("forwarded:\(message)")
                return .same
            }
        )

        first.cluster.join(node: second.cluster.uniqueNode.node)

        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        // first we manually construct the "right second path"; Don't do this in normal production code
        let uniqueSecondAddress = ActorAddress(local: second.cluster.uniqueNode, path: refOnSecondSystem.path, incarnation: refOnSecondSystem.address.incarnation)
        // to then obtain a second ref ON the `system`, meaning that the node within uniqueSecondAddress is a second one
        let resolvedRef = self.resolveRef(first, type: String.self, address: uniqueSecondAddress, on: second)
        // the resolved ref is a first resource on the `system` and points via the right association to the second actor
        // inside system `second`. Sending messages to a ref constructed like this will make the messages go over remoting.
        resolvedRef.tell("HELLO")

        try probeOnSecond.expectMessage("forwarded:HELLO")
    }

    func test_ignore_attemptToSelfJoinANode() throws {
        let alone = self.setUpNode("alone")

        alone.cluster.join(node: alone.cluster.uniqueNode.node) // "self join", should simply be ignored

        let testKit = self.testKit(alone)
        try testKit.eventually(within: .seconds(3)) {
            let snapshot: Cluster.Membership = alone.cluster.membershipSnapshot
            if snapshot.count != 1 {
                throw TestError("Expected membership to include self node, was: \(snapshot)")
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Concurrently initiated handshakes to same node should both get completed

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_incoming_outgoing() throws {
        let (first, second) = self.setUpPair()

        // here we attempt to make a race where the nodes race to join each other
        // again, only one association should be created.
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))
        second.cluster.ref.tell(.command(.handshakeWith(first.cluster.uniqueNode.node)))

        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withExactly: first.settings.cluster.uniqueBindNode)
    }

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_outgoing_outgoing() throws {
        let (first, second) = setUpPair()

        // we issue two handshakes quickly after each other, both should succeed but there should only be one association established (!)
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))

        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withExactly: first.settings.cluster.uniqueBindNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Retry handshakes

    func test_handshake_shouldKeepTryingUntilOtherNodeBindsPort() throws {
        let first = setUpNode("first")

        let secondPort = first.cluster.uniqueNode.node.port + 10
        // second is NOT started, but we already ask first to handshake with the second one (which will fail, though the node should keep trying)
        let secondNode = Node(systemName: "second", host: "127.0.0.1", port: secondPort)

        first.cluster.join(node: secondNode)
        sleep(3) // we give it some time to keep failing to connect, so the second node is not yet started

        let second = setUpNode("second") { settings in
            settings.cluster.bindPort = secondPort
        }

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
    }

    func test_handshake_shouldStopTryingWhenMaxAttemptsExceeded() throws {
        let first = setUpNode("first") { settings in
            settings.cluster.handshakeReconnectBackoff = Backoff.exponential(
                initialInterval: .milliseconds(100),
                maxAttempts: 2
            )
        }

        let secondPort = first.cluster.uniqueNode.node.port + 10
        // second is NOT started, but we already ask first to handshake with the second one (which will fail, though the node should keep trying)
        let secondNode = Node(systemName: "second", host: "127.0.0.1", port: secondPort)

        first.cluster.join(node: secondNode)
        sleep(1) // we give it some time to keep failing to connect (and exhaust the retries)

        let logs = self.capturedLogs(of: first)
        try logs.awaitLogContaining(self.testKit(first), text: "Giving up on handshake with node [sact://second@127.0.0.1:9011]")
    }

    func test_handshake_shouldNotAssociateWhenRejected() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        let second = self.setUpNode("second")

        first.cluster.join(node: second.cluster.uniqueNode.node)

        try assertNotAssociated(system: first, node: second.cluster.uniqueNode)
        try assertNotAssociated(system: second, node: first.cluster.uniqueNode)
    }

    func test_handshake_shouldNotifyOnRejection() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        let second = self.setUpNode("second")

        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.uniqueNode.node)))

        try assertNotAssociated(system: first, node: second.cluster.uniqueNode)
        try assertNotAssociated(system: second, node: first.cluster.uniqueNode)

        try self.capturedLogs(of: first)
            .awaitLogContaining(
                self.testKit(first),
                text: "Handshake rejected by [sact://second@127.0.0.1:9002], reason: incompatibleProtocolVersion"
            )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Leaving/down rejecting handshakes

    func test_handshake_shouldRejectIfNodeIsLeavingOrDown() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster.onDownAction = .none // don't shutdown this node (keep process alive)
        }
        let second = self.setUpNode("second")

        first.cluster.down(node: first.cluster.uniqueNode.node)

        let testKit = self.testKit(first)
        try testKit.eventually(within: .seconds(3)) {
            let snapshot: Cluster.Membership = first.cluster.membershipSnapshot
            if let selfMember = snapshot.uniqueMember(first.cluster.uniqueNode) {
                if selfMember.status == .down {
                    () // good
                } else {
                    throw testKit.error("Expecting \(first.cluster.uniqueNode) to become [.down] but was \(selfMember.status). Membership: \(pretty: snapshot)")
                }
            } else {
                throw testKit.error("No self member for \(first.cluster.uniqueNode)! Membership: \(pretty: snapshot)")
            }
        }

        // now we try to join the "already down" node; it should reject any such attempts
        second.cluster.ref.tell(.command(.handshakeWith(first.cluster.uniqueNode.node)))

        try assertNotAssociated(system: first, node: second.cluster.uniqueNode)
        try assertNotAssociated(system: second, node: first.cluster.uniqueNode)

        try self.capturedLogs(of: second)
            .awaitLogContaining(
                self.testKit(second),
                text: "Handshake rejected by [sact://first@127.0.0.1:9001], reason: Node already leaving cluster."
            )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: second control caching

    func test_cachedSecondControlsWithSameNodeID_shouldNotOverwriteEachOther() throws {
        let (first, second) = setUpPair()
        second.cluster.join(node: first.cluster.uniqueNode.node)

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        let thirdSystem = self.setUpNode("third") { settings in
            settings.cluster.enabled = true
            settings.cluster.nid = second.settings.cluster.nid
            settings.cluster.node.port = 9119
        }

        thirdSystem.cluster.join(node: first.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: [second.cluster.uniqueNode, thirdSystem.settings.cluster.uniqueBindNode])

        first._cluster?._testingOnly_associations.count.shouldEqual(2)
    }

    func test_sendingMessageToNotYetAssociatedNode_mustCauseAssociationAttempt() throws {
        let first = self.setUpNode("first")
        let second = self.setUpNode("second")

        // actor on `second` node
        let p2 = self.testKit(second).spawnTestProbe(expecting: String.self)
        let secondOne: _ActorRef<String> = try second.spawn("second-1", .receive { _, message in
            p2.tell("Got:\(message)")
            return .same
        })
        let secondFullAddress = ActorAddress(remote: second.cluster.uniqueNode, path: secondOne.path, incarnation: secondOne.address.incarnation)

        // we somehow obtained a ref to secondOne (on second node) without associating second yet
        // e.g. another node sent us that ref; This must cause buffering of sends to second and an association to be created.

        let resolveContext = ResolveContext<String>(address: secondFullAddress, system: first)
        let ref = first._resolve(context: resolveContext)

        try assertNotAssociated(system: first, node: second.cluster.uniqueNode)
        try assertNotAssociated(system: second, node: first.cluster.uniqueNode)

        // will be buffered until associated, and then delivered:
        ref.tell("Hello 1")
        ref.tell("Hello 2")
        ref.tell("Hello 3")

        try p2.expectMessage("Got:Hello 1")
        try p2.expectMessage("Got:Hello 2")
        try p2.expectMessage("Got:Hello 3")

        try assertAssociated(first, withExactly: second.cluster.uniqueNode)
        try assertAssociated(second, withExactly: first.cluster.uniqueNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Change membership on Down detected

    func test_down_self_shouldChangeMembershipSelfToBeDown() throws {
        let (first, second) = setUpPair { settings in
            settings.cluster.onDownAction = .none // as otherwise we can't inspect if we really changed the status to .down, as we might shutdown too quickly :-)
        }

        second.cluster.join(node: first.cluster.uniqueNode.node)
        try assertAssociated(first, withExactly: second.cluster.uniqueNode)

        // down myself
        first.cluster.down(node: first.cluster.uniqueNode.node)

        let firstProbe = self.testKit(first).spawnTestProbe(expecting: Cluster.Membership.self)
        let secondProbe = self.testKit(second).spawnTestProbe(expecting: Cluster.Membership.self)

        // we we down first on first, it should become down there:
        try self.testKit(first).eventually(within: .seconds(3)) {
            first.cluster.ref.tell(.query(.currentMembership(firstProbe.ref)))
            let firstMembership = try firstProbe.expectMessage()

            guard let selfMember = firstMembership.uniqueMember(first.cluster.uniqueNode) else {
                throw self.testKit(second).error("No self member in membership! Wanted: \(first.cluster.uniqueNode)", line: #line - 1)
            }

            try self.assertMemberStatus(on: first, node: first.cluster.uniqueNode, is: .down)
            guard selfMember.status == .down else {
                throw self.testKit(first).error("Wanted self member to be DOWN, but was: \(selfMember)", line: #line - 1)
            }
        }

        // and the second node should also notice
        try self.testKit(second).eventually(within: .seconds(3)) {
            second.cluster.ref.tell(.query(.currentMembership(secondProbe.ref)))
            let secondMembership = try secondProbe.expectMessage()

            // and the first node should also propagate the Down information to the second node
            // although this may be a best effort since the first can just shut down if it wanted to,
            // this scenario assumes a graceful leave though:

            guard let firstMemberObservedOnSecond = secondMembership.uniqueMember(first.cluster.uniqueNode) else {
                throw self.testKit(second).error("\(second) does not know about the \(first.cluster.uniqueNode) at all...!", line: #line - 1)
            }

            guard firstMemberObservedOnSecond.status == .down else {
                throw self.testKit(second).error("Wanted to see \(first.cluster.uniqueNode) as DOWN on \(second), but was still: \(firstMemberObservedOnSecond)", line: #line - 1)
            }
        }
    }
}
