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

final class ClusterAssociationTests: ClusteredNodesTestBase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/replicator",
            "/system/cluster/swim",
        ]
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path, accept association

    func test_boundServer_shouldAcceptAssociate() throws {
        let (local, remote) = self.setUpPair()

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)
    }

    func test_boundServer_shouldAcceptAssociate_raceFromBothNodes() throws {
        let (local, remote) = self.setUpPair()
        let n3 = self.setUpNode("node-3")
        let n4 = self.setUpNode("node-4")
        let n5 = self.setUpNode("node-5")
        let n6 = self.setUpNode("node-6")

        local.cluster.join(node: remote.cluster.node.node)
        remote.cluster.join(node: local.cluster.node.node)

        n3.cluster.join(node: local.cluster.node.node)
        local.cluster.join(node: n3.cluster.node.node)

        n4.cluster.join(node: local.cluster.node.node)
        local.cluster.join(node: n4.cluster.node.node)

        n5.cluster.join(node: local.cluster.node.node)
        local.cluster.join(node: n5.cluster.node.node)

        n6.cluster.join(node: local.cluster.node.node)
        local.cluster.join(node: n6.cluster.node.node)

        try assertAssociated(local, withAtLeast: remote.cluster.node)
        try assertAssociated(remote, withAtLeast: local.cluster.node)
    }

    func test_handshake_shouldNotifyOnSuccess() throws {
        try shouldNotThrow {
            let (local, remote) = self.setUpPair()

            local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node)))

            try assertAssociated(local, withExactly: remote.cluster.node)
            try assertAssociated(remote, withExactly: local.cluster.node)
        }
    }

    func test_handshake_shouldNotifySuccessWhenAlreadyConnected() throws {
        try shouldNotThrow {
            let (local, remote) = self.setUpPair()

            local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node)))

            try assertAssociated(local, withExactly: remote.cluster.node)
            try assertAssociated(remote, withExactly: local.cluster.node)

            local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node)))

            try assertAssociated(local, withExactly: remote.cluster.node)
            try assertAssociated(remote, withExactly: local.cluster.node)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Joining into existing cluster

    func test_association_sameAddressNodeJoin_shouldOverrideExistingNode() throws {
        try shouldNotThrow {
            let (first, second) = self.setUpPair()

            let secondName = second.cluster.node.node.systemName
            let remotePort = second.cluster.node.port

            let firstEventsProbe = self.testKit(first).spawnTestProbe(expecting: Cluster.Event.self)
            let secondEventsProbe = self.testKit(second).spawnTestProbe(expecting: Cluster.Event.self)
            first.cluster.events.subscribe(firstEventsProbe.ref)
            second.cluster.events.subscribe(secondEventsProbe.ref)

            first.cluster.join(node: second.cluster.node.node)

            try assertAssociated(first, withExactly: second.cluster.node)
            try assertAssociated(second, withExactly: first.cluster.node)

            let oldSecond = second
            let shutdown = oldSecond.shutdown() // kill remote node
            try shutdown.wait(atMost: .seconds(3))

            let secondReplacement = self.setUpNode(secondName + "-REPLACEMENT") { settings in
                settings.cluster.bindPort = remotePort
            }
            let secondReplacementEventsProbe = self.testKit(secondReplacement).spawnTestProbe(expecting: Cluster.Event.self)
            secondReplacement.cluster.events.subscribe(secondReplacementEventsProbe.ref)
            second.cluster.events.subscribe(secondReplacementEventsProbe.ref)

            // the new replacement node is now going to initiate a handshake with 'local' which knew about the previous
            // instance (oldRemote) on the same node; It should accept this new handshake, and ban the previous node.
            secondReplacement.cluster.join(node: first.cluster.node.node)

            // verify we are associated ONLY with the appropriate nodes now;
            try assertAssociated(first, withExactly: [secondReplacement.cluster.node])
            try assertAssociated(secondReplacement, withExactly: [first.cluster.node])
        }
    }

    func test_association_shouldAllowSendingToRemoteReference() throws {
        try shouldNotThrow {
            let (local, remote) = self.setUpPair()

            let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
            let refOnRemoteSystem: ActorRef<String> = try remote.spawn(
                    "remoteAcquaintance",
                    .receiveMessage { message in
                        probeOnRemote.tell("forwarded:\(message)")
                        return .same
                    }
            )

            local.cluster.join(node: remote.cluster.node.node)

            try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

            // first we manually construct the "right remote path"; Don't do this in normal production code
            let uniqueRemoteAddress = ActorAddress(node: remote.cluster.node, path: refOnRemoteSystem.path, incarnation: refOnRemoteSystem.address.incarnation)
            // to then obtain a remote ref ON the `system`, meaning that the node within uniqueRemoteAddress is a remote one
            let resolvedRef = self.resolveRef(local, type: String.self, address: uniqueRemoteAddress, on: remote)
            // the resolved ref is a local resource on the `system` and points via the right association to the remote actor
            // inside system `remote`. Sending messages to a ref constructed like this will make the messages go over remoting.
            resolvedRef.tell("HELLO")

            try probeOnRemote.expectMessage("forwarded:HELLO")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Concurrently initiated handshakes to same node should both get completed

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_incoming_outgoing() throws {
        let (first, second) = self.setUpPair()

        // here we attempt to make a race where the nodes race to join each other
        // again, only one association should be created.
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.node.node)))
        second.cluster.ref.tell(.command(.handshakeWith(first.cluster.node.node)))

        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withExactly: first.settings.cluster.uniqueBindNode)
    }

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_outgoing_outgoing() throws {
        let (first, second) = setUpPair()

        // we issue two handshakes quickly after each other, both should succeed but there should only be one association established (!)
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.node.node)))
        first.cluster.ref.tell(.command(.handshakeWith(second.cluster.node.node)))

        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
        try assertAssociated(second, withExactly: first.settings.cluster.uniqueBindNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Retry associations

    func test_association_shouldKeepTryingUntilOtherNodeBindsPort() throws {
        let local = setUpNode("local")

        let remotePort = local.cluster.node.node.port + 10
        // remote is NOT started, but we already ask local to handshake with the remote one (which will fail, though the node should keep trying)
        let remoteNode = Node(systemName: "remote", host: "127.0.0.1", port: remotePort)

        local.cluster.join(node: remoteNode)
        sleep(1) // we give it some time to keep failing to connect, so the second node is not yet started

        let remote = setUpNode("remote") { settings in
            settings.cluster.bindPort = remotePort
        }

        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)
    }

    func test_association_shouldNotAssociateWhenRejected() throws {
        let local = self.setUpNode("local") { settings in
            settings.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        let remote = self.setUpNode("remote")

        local.cluster.join(node: remote.cluster.node.node)

        try assertNotAssociated(system: local, node: remote.cluster.node)
        try assertNotAssociated(system: remote, node: local.cluster.node)
    }

    func test_handshake_shouldNotifyOnRejection() throws {
        let local = self.setUpNode("local") { settings in 
            settings.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        let remote = self.setUpNode("remote")

        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node)))

        try assertNotAssociated(system: local, node: remote.cluster.node)
        try assertNotAssociated(system: remote, node: local.cluster.node)

        try self.capturedLogs(of: local).awaitLogContaining(self.testKit(local), text: "incompatibleProtocolVersion(local:")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Remote control caching

    func test_cachedRemoteControlsWithSameNodeID_shouldNotOverwriteEachOther() throws {
        let (local, remote) = setUpPair()
        remote.cluster.join(node: local.cluster.node.node)

        try assertAssociated(local, withExactly: remote.cluster.node)

        let thirdSystem = self.setUpNode("third") { settings in
            settings.cluster.enabled = true
            settings.cluster.nid = remote.settings.cluster.nid
            settings.cluster.node.port = 9119
        }

        thirdSystem.cluster.join(node: local.cluster.node.node)
        try assertAssociated(local, withExactly: [remote.cluster.node, thirdSystem.settings.cluster.uniqueBindNode])

        local._cluster?._testingOnly_associations.count.shouldEqual(2)
    }

    func test_sendingMessageToNotYetAssociatedNode_mustCauseAssociationAttempt() throws {
        let first = self.setUpNode("first")
        let second = self.setUpNode("second")

        // actor on `second` node
        let p2 = self.testKit(second).spawnTestProbe(expecting: String.self)
        let secondOne: ActorRef<String> = try second.spawn("second-1", .receive { _, message in
            p2.tell("Got:\(message)")
            return .same
        })
        var secondFullAddress = secondOne.address
        secondFullAddress.node = second.cluster.node

        // we somehow obtained a ref to secondOne (on second node) without associating second yet
        // e.g. another node sent us that ref; This must cause buffering of sends to second and an association to be created.

        let resolveContext = ResolveContext<String>(address: secondFullAddress, system: first)
        let ref = first._resolve(context: resolveContext)

        try assertNotAssociated(system: first, node: second.cluster.node)
        try assertNotAssociated(system: second, node: first.cluster.node)

        // will be buffered until associated, and then delivered:
        ref.tell("Hello 1")
        ref.tell("Hello 2")
        ref.tell("Hello 3")

        try p2.expectMessage("Got:Hello 1")
        try p2.expectMessage("Got:Hello 2")
        try p2.expectMessage("Got:Hello 3")

        try assertAssociated(first, withExactly: second.cluster.node)
        try assertAssociated(second, withExactly: first.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Change membership on Down detected

    func test_down_self_shouldChangeMembershipSelfToBeDown() throws {
        try shouldNotThrow {
            let (first, second) = setUpPair { settings in
                settings.cluster.onDownAction = .none // as otherwise we can't inspect if we really changed the status to .down, as we might shutdown too quickly :-)
            }

            second.cluster.join(node: first.cluster.node.node)
            try assertAssociated(first, withExactly: second.cluster.node)

            // down myself
            first.cluster.down(node: first.cluster.node.node)

            let localProbe = self.testKit(first).spawnTestProbe(expecting: Cluster.Membership.self)
            let remoteProbe = self.testKit(second).spawnTestProbe(expecting: Cluster.Membership.self)

            // we we down local on local, it should become down there:
            try self.testKit(first).eventually(within: .seconds(3)) {
                first.cluster.ref.tell(.query(.currentMembership(localProbe.ref)))
                let firstMembership = try localProbe.expectMessage()

                guard let selfMember = firstMembership.uniqueMember(first.cluster.node) else {
                    throw self.testKit(second).error("No self member in membership! Wanted: \(first.cluster.node)", line: #line - 1)
                }

                try self.assertMemberStatus(on: first, node: first.cluster.node, is: .down)
                guard selfMember.status == .down else {
                    throw self.testKit(first).error("Wanted self member to be DOWN, but was: \(selfMember)", line: #line - 1)
                }
            }

            // and the second node should also notice
            try self.testKit(second).eventually(within: .seconds(3)) {
                second.cluster.ref.tell(.query(.currentMembership(remoteProbe.ref)))
                let secondMembership = try remoteProbe.expectMessage()

                // and the local node should also propagate the Down information to the remote node
                // although this may be a best effort since the local can just shut down if it wanted to,
                // this scenario assumes a graceful leave though:

                guard let localMemberObservedOnRemote = secondMembership.uniqueMember(first.cluster.node) else {
                    throw self.testKit(second).error("\(second) does not know about the \(first.cluster.node) at all...!", line: #line - 1)
                }

                guard localMemberObservedOnRemote.status == .down else {
                    throw self.testKit(second).error("Wanted to see \(first.cluster.node) as DOWN on \(second), but was still: \(localMemberObservedOnRemote)", line: #line - 1)
                }
            }
        }
    }
}
