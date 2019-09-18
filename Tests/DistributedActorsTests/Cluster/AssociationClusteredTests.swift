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
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path, accept association

    func test_boundServer_shouldAcceptAssociate() throws {
        let (local, remote) = self.setUpPair()

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)
    }

    func test_handshake_shouldNotifyOnSuccess() throws {
        let (local, remote) = self.setUpPair()
        let p = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p.ref)))

        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)

        try p.expectMessage(.success(remote.cluster.node), within: .seconds(3))
    }

    func test_handshake_shouldNotifySuccessWhenAlreadyConnected() throws {
        let (local, remote) = self.setUpPair()
        let p = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p.ref)))

        try assertAssociated(local, withExactly: remote.cluster.node)
        try assertAssociated(remote, withExactly: local.cluster.node)

        try p.expectMessage(.success(remote.cluster.node))

        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p.ref)))

        try p.expectMessage(.success(remote.cluster.node))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Joining into existing cluster
    override var captureLogs: Bool {
        return false
    }

    func test_association_sameAddressNodeJoin_shouldOverrideExistingNode() throws {
        try shouldNotThrow {
            let (first, second) = self.setUpPair()

            let secondName = second.cluster.node.node.systemName
            let remotePort = second.cluster.node.port

            let firstEventsProbe = self.testKit(first).spawnTestProbe(expecting: ClusterEvent.self)
            let secondEventsProbe = self.testKit(second).spawnTestProbe(expecting: ClusterEvent.self)
            first.cluster.events.subscribe(firstEventsProbe.ref)
            second.cluster.events.subscribe(secondEventsProbe.ref)

            first.cluster.join(node: second.cluster.node.node)

            try assertAssociated(first, withExactly: second.cluster.node)
            try assertAssociated(second, withExactly: first.cluster.node)

            let oldSecond = second
            oldSecond.shutdown() // kill remote node

            let secondReplacement = self.setUpNode(secondName + "-REPLACEMENT") { settings in
                settings.cluster.bindPort = remotePort
            }
            let secondReplacementEventsProbe = self.testKit(secondReplacement).spawnTestProbe(expecting: ClusterEvent.self)
            secondReplacement.cluster.events.subscribe(secondReplacementEventsProbe.ref)
            second.cluster.events.subscribe(secondReplacementEventsProbe.ref)

            let replacementUniqueAddress = secondReplacement.settings.cluster.uniqueBindNode
            pinfo("replacementUniqueAddress = \(reflecting: replacementUniqueAddress)")

            // the new replacement node is now going to initiate a handshake with 'local' which knew about the previous
            // instance (oldRemote) on the same node; It should accept this new handshake, and ban the previous node.
            secondReplacement.cluster.join(node: first.cluster.node.node)

            // verify we are associated only with the appropriate nodes now;
            try assertAssociated(first, withExactly: [replacementUniqueAddress])
            try assertAssociated(secondReplacement, withExactly: [first.cluster.node])

            // old node should have been removed from membership, by new one on same node "taking over"
            // note that connections to old node should also been severed

            sleep(2)
            self.pinfoMembership(first)
            self.pinfoMembership(secondReplacement)

            // ==== Assert cluster events on each node
            while let event = try firstEventsProbe.maybeExpectMessage() {
                pprint("first      EVT : \(String(reflecting: event))")
            }
//            while let event = try secondEventsProbe.maybeExpectMessage() {
//                pprint("second     EVT : \(String(reflecting: event))")
//            }
            while let event = try secondEventsProbe.maybeExpectMessage() {
                pprint("secondREPL EVT : \(String(reflecting: event))")
            }
        }
    }

    func test_association_shouldAllowSendingToRemoteReference() throws {
        let (local, remote) = self.setUpPair()

        let probeOnRemote = self.testKit(remote).spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<String> = try remote.spawn("remoteAcquaintance", .receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        })

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let uniqueRemoteAddress = ActorAddress(node: remote.cluster.node, path: refOnRemoteSystem.path, incarnation: refOnRemoteSystem.address.incarnation)
        // to then obtain a remote ref ON the `system`, meaning that the node within uniqueRemoteAddress is a remote one
        let resolvedRef = self.resolveRef(local, type: String.self, address: uniqueRemoteAddress, on: remote)
        // the resolved ref is a local resource on the `system` and points via the right association to the remote actor
        // inside system `remote`. Sending messages to a ref constructed like this will make the messages go over remoting.
        resolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Concurrently initiated handshakes to same node should both get completed

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_incoming_outgoing() throws {
        let (local, remote) = self.setUpPair()

        let p7337 = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)
        let p8228 = self.testKit(remote).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        // here we attempt to make a race where the nodes race to join each other
        // again, only one association should be created.
        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p7337.ref)))
        remote.cluster.ref.tell(.command(.handshakeWith(local.cluster.node.node, replyTo: p8228.ref)))

        _ = try p7337.expectMessage()
        _ = try p8228.expectMessage()

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
        try assertAssociated(remote, withExactly: local.settings.cluster.uniqueBindNode)
    }

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_outgoing_outgoing() throws {
        let (local, remote) = setUpPair()

        let p7337 = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)
        let p8228 = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        // we issue two handshakes quickly after each other, both should succeed but there should only be one association established (!)
        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p7337.ref)))
        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p8228.ref)))

        _ = try p7337.expectMessage()
        _ = try p8228.expectMessage()

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
        try assertAssociated(remote, withExactly: local.settings.cluster.uniqueBindNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Retry associations

    func test_association_shouldKeepTryingUntilOtherNodeBindsPort() throws {
        let local = setUpNode("local")

        let remotePort = local.cluster.node.node.port + 10
        // remote is NOT started, but we already ask local to handshake with the remote one (which will fail, though the node should keep trying)
        let remoteNode = Node(systemName: "remote", host: "localhost", port: remotePort)

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

        try assertNotAssociated(system: local, expectAssociatedNode: remote.cluster.node)
        try assertNotAssociated(system: remote, expectAssociatedNode: local.cluster.node)
    }

    func test_handshake_shouldNotifyOnRejection() throws {
        let local = self.setUpNode("local") {
            $0.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        let remote = self.setUpNode("remote")

        let p = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.cluster.ref.tell(.command(.handshakeWith(remote.cluster.node.node, replyTo: p.ref)))

        try assertNotAssociated(system: local, expectAssociatedNode: remote.cluster.node)
        try assertNotAssociated(system: remote, expectAssociatedNode: local.cluster.node)

        switch try p.expectMessage() {
        case ClusterShell.HandshakeResult.failure(let err):
            "\(err)".shouldContain("incompatibleProtocolVersion(local:")
            () // ok
        default:
            throw p.error()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Remote control caching

    func test_cachedRemoteControlsWithSameNodeID_shouldNotOverwriteEachOther() throws {
        let (local, remote) = setUpPair()
        remote.cluster.join(node: local.cluster.node.node)

        try assertAssociated(local, withExactly: remote.cluster.node)

        let thirdSystem = ActorSystem("ClusterAssociationTests") { settings in
            settings.cluster.enabled = true
            settings.cluster.nid = remote.settings.cluster.nid
            settings.cluster.node.port = 9119
        }
        defer { thirdSystem.shutdown().wait() }

        thirdSystem.cluster.join(node: local.cluster.node.node)
        try assertAssociated(local, withExactly: [remote.cluster.node, thirdSystem.settings.cluster.uniqueBindNode])

        local._cluster?.associationRemoteControls.count.shouldEqual(2)
    }

    // FIXME: once initiated, handshake seem to retry until they succeed, that seems
    //      like a problem and should be fixed. This test should be re-enabled,
    //      once issue #724 (handshakes should not retry forever) is resolved
    func disabled_test_handshake_shouldNotifyOnConnectionFailure() throws {
        let local = setUpNode("local")

        let p = self.testKit(local).spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        var node = local.cluster.node.node
        node.port = node.port + 10

        local.cluster.ref.tell(.command(.handshakeWith(node, replyTo: p.ref))) // TODO: nicer API

        switch try p.expectMessage(within: .seconds(1)) {
        case ClusterShell.HandshakeResult.failure:
            () // ok
        default:
            throw p.error()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Change membership on Down detected

    func test_down_self_shouldChangeMembershipSelfToBeDown() throws {
        let (local, remote) = setUpPair()
        remote.cluster.join(node: local.cluster.node.node)
        try assertAssociated(local, withExactly: remote.cluster.node)

        local.cluster.down(node: local.cluster.node.node)

        let localProbe = self.testKit(local).spawnTestProbe(expecting: Membership.self)

        // we we down local on local, it should become down there:
        try self.testKit(local).eventually(within: .seconds(3)) {
            local.cluster.ref.tell(.query(.currentMembership(localProbe.ref)))
            let localMembership = try localProbe.expectMessage()

            guard let selfMember = localMembership.member(local.cluster.node) else {
                throw self.testKit(remote).error("No self member in membership! Wanted: \(local.cluster.node)", line: #line - 1)
            }
            guard selfMember.status == .down else {
                throw self.testKit(local).error("Wanted self member to be DOWN, but was: \(selfMember)", line: #line - 1)
            }

            // and the local node should also propagate the Down information to the remote node
            // although this may be a best effort since the local can just shut down if it wanted to,
            // this scenario assumes a graceful leave though:

            remote.cluster.ref.tell(.query(.currentMembership(localProbe.ref)))
            let remoteMembership = try localProbe.expectMessage()

            guard let localMemberObservedOnRemote = remoteMembership.member(local.cluster.node) else {
                throw self.testKit(remote).error("\(remote) does not know about the \(local.cluster.node) at all...!", line: #line - 1)
            }

            guard localMemberObservedOnRemote.status == .down else {
                throw self.testKit(remote).error("Wanted to see \(local.cluster.node) as DOWN on \(remote), but was still: \(localMemberObservedOnRemote)", line: #line - 1)
            }
        }

        // and the remote node should also notice
    }
}
