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

import NIO
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class ClusterAssociationTests: ClusteredTwoNodesTestBase {

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Happy path, accept association

    func test_boundServer_shouldAcceptAssociate() throws {
        self.setUpBoth()

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: self.remoteUniqueAddress)
        try assertAssociated(remote, with: self.localUniqueAddress)
    }

    func test_handshake_shouldNotifyOnSuccess() throws {
        self.setUpBoth()
        let p = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: p.ref))) // TODO nicer API

        try assertAssociated(local, with: self.remoteUniqueAddress)
        try assertAssociated(remote, with: self.localUniqueAddress)

        try p.expectMessage(.success(self.remoteUniqueAddress))
    }

    func test_handshake_shouldNotifySuccessWhenAlreadyConnected() throws {
        self.setUpBoth()
        let p = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: p.ref))) // TODO nicer API

        try assertAssociated(local, with: self.remoteUniqueAddress)
        try assertAssociated(remote, with: self.localUniqueAddress)

        try p.expectMessage(.success(self.remoteUniqueAddress))

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: p.ref))) // TODO nicer API

        try p.expectMessage(.success(self.remoteUniqueAddress))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Joining into existing cluster

    func test_association_sameAddressNodeJoin_shouldOverrideExistingNode() throws {
        self.setUpBoth()

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: nil))) // TODO nicer API

        try assertAssociated(self.local, with: self.remoteUniqueAddress)
        try assertAssociated(self.remote, with: self.localUniqueAddress)

        let oldRemote = self.remote
        oldRemote.shutdown() // kill remote node

        self.setUpRemote() // new system, same exact address, however new UID
        let replacementRemote = self.remote
        let replacementUniqueAddress = replacementRemote.settings.cluster.uniqueBindAddress

        // the new replacement node is now going to initiate a handshake with 'local' which knew about the previous
        // instance (oldRemote) on the same address; It should accept this new handshake, and ban the previous node.
        replacementRemote.clusterShell.tell(.command(.handshakeWith(self.localUniqueAddress.address, replyTo: nil))) // TODO nicer API

        // verify we are associated only with the appropriate addresses now;
        //
        // old address should have been removed from membership, by new one on same address "taking over"
        // note that connections to old node should also been severed // TODO cover this in a test
        try assertAssociated(self.local, withExactly: [replacementUniqueAddress])
        try assertAssociated(self.remote, withExactly: [self.localUniqueAddress])
    }

    func test_association_shouldAllowSendingToRemoteReference() throws {
        self.setUpBoth()

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        }, name: "remoteAcquaintance")

        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueAddress.address, replyTo: nil))) // TODO nicer API

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindAddress)

        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNodeAddress = remote.settings.cluster.uniqueBindAddress
        var uniqueRemotePath: UniqueActorPath = refOnRemoteSystem.path
        uniqueRemotePath.address = remoteNodeAddress // since refOnRemoteSystem is "local" there, it has no address; thus we set it
        // to then obtain a remote ref ON the `system`, meaning that the address within remotePath is a remote one
        let resolveContext = ResolveContext<String>(path: uniqueRemotePath, system: self.local)
        let resolvedRef = local._resolve(context: resolveContext)
        // the resolved ref is a local resource on the `system` and points via the right association to the remote actor
        // inside system `remote`. Sending messages to a ref constructed like this will make the messages go over remoting.
        resolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Concurrently initiated handshakes to same node should both get completed

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_incoming_outgoing() throws {
        self.setUpBoth()

        let p7337 = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)
        let p8228 = remoteTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        // here we attempt to make a race where the nodes race to join each other
        // again, only one association should be created.
        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueAddress.address, replyTo: p7337.ref)))
        remote.clusterShell.tell(.command(.handshakeWith(localUniqueAddress.address, replyTo: p8228.ref)))

        let handshakeResult1 = try p7337.expectMessage()
        let handshakeResult2 = try p8228.expectMessage()

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindAddress)
        try assertAssociated(remote, with: local.settings.cluster.uniqueBindAddress)
    }

    func test_association_shouldEstablishSingleAssociationForConcurrentlyInitiatedHandshakes_outgoing_outgoing() throws {
        self.setUpBoth()

        let p7337 = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)
        let p8228 = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        // we issue two handshakes quickly after each other, both should succeed but there should only be one association established (!)
        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueAddress.address, replyTo: p7337.ref)))
        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueAddress.address, replyTo: p8228.ref)))

        let handshakeResult1 = try p7337.expectMessage()
        let handshakeResult2 = try p8228.expectMessage()

        try assertAssociated(local, with: remote.settings.cluster.uniqueBindAddress)
        try assertAssociated(remote, with: local.settings.cluster.uniqueBindAddress)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Retry associations

    func test_association_shouldKeepTryingUntilOtherNodeBindsPort() throws {
        setUpLocal()
        // remote is NOT started, but we already ask local to handshake with the remote one (which will fail, though the node should keep trying)
        let remoteAddress = NodeAddress(systemName: local.name, host: "localhost", port: self.remotePort)
        local.clusterShell.tell(.command(.handshakeWith(remoteAddress, replyTo: nil))) // TODO nicer API
        sleep(1) // we give it some time to keep failing to connect, so the second node is not yet started
        setUpRemote()

        try assertAssociated(local, with: self.remoteUniqueAddress)
        try assertAssociated(remote, with: self.localUniqueAddress)
    }

    func test_association_shouldNotAssociateWhenRejected() throws {
        setUpLocal {
            $0.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        setUpRemote()

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: nil))) // TODO nicer API

        try assertNotAssociated(system: local, expectAssociatedAddress: self.remoteUniqueAddress)
        try assertNotAssociated(system: remote, expectAssociatedAddress: self.localUniqueAddress)
    }

    func test_handshake_shouldNotifyOnRejection() throws {
        setUpLocal {
            $0.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        setUpRemote()

        let p = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        local.clusterShell.tell(.command(.handshakeWith(self.remoteUniqueAddress.address, replyTo: p.ref))) // TODO nicer API

        try assertNotAssociated(system: local, expectAssociatedAddress: self.remoteUniqueAddress)
        try assertNotAssociated(system: remote, expectAssociatedAddress: self.localUniqueAddress)

        switch try p.expectMessage() {
        case ClusterShell.HandshakeResult.failure:
            () // ok
        default:
            throw p.error()
        }
    }

    // TODO: once initiated, handshake seem to retry until they succeed, that seems
    //      like a problem and should be fixed. This test should be re-enabled,
    //      once https://github.com/apple/swift-distributed-actors/issues/724 (handshakes should not retry forever) is resolved
    func disabled_test_handshake_shouldNotifyOnConnectionFailure() throws {
        setUpLocal()

        let p = localTestKit.spawnTestProbe(expecting: ClusterShell.HandshakeResult.self)

        var address = self.localUniqueAddress.address
        address.port = address.port + 10

        local.clusterShell.tell(.command(.handshakeWith(address, replyTo: p.ref))) // TODO nicer API

        switch try p.expectMessage(within: .seconds(1)) {
        case ClusterShell.HandshakeResult.failure:
            () // ok
        default:
            throw p.error()
        }
    }
}
