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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class RemotingAssociationTests: RemotingTestBase {

    override var systemName: String {
        return "RemotingAssociationTests"
    }

    func test_boundServer_shouldAcceptAssociate() throws {
        self.setUpBoth()

        local.remoting.tell(.command(.handshakeWith(self.remoteUniqueAddress.address))) // TODO nicer API

        try assertAssociated(system: self.local, expectAssociatedAddress: self.remoteUniqueAddress)
        try assertAssociated(system: self.remote, expectAssociatedAddress: self.localUniqueAddress)
    }

    func test_association_shouldAllowSendingToRemoteReference() throws {
        self.setUpBoth()

        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        }, name: "remoteAcquaintance")

        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API

        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.cluster.uniqueBindAddress)

        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNodeAddress = remote.settings.cluster.uniqueBindAddress
        var uniqueRemotePath: UniqueActorPath = refOnRemoteSystem.path
        uniqueRemotePath.address = remoteNodeAddress // since refOnRemoteSystem is "local" there, it has no address; thus we set it
        // to then obtain a remote ref ON the `system`, meaning that the address within remotePath is a remote one
        let resolveContext = ResolveContext<String>(path: uniqueRemotePath, deadLetters: local.deadLetters)
        let resolvedRef = local._resolve(context: resolveContext)
        // the resolved ref is a local resource on the `system` and points via the right association to the remote actor
        // inside system `remote`. Sending messages to a ref constructed like this will make the messages go over remoting.
        resolvedRef.tell("HELLO")

        try probeOnRemote.expectMessage("forwarded:HELLO")
    }

    func test_association_shouldKeepTryingUntilOtherNodeBindsPort() throws {
        setUpLocal()
        // remote is NOT started, but we already ask local to handshake with the remote one (which will fail, though the node should keep trying)
        let remoteAddress = NodeAddress(systemName: local.name, host: "localhost", port: self.remotePort)
        local.remoting.tell(.command(.handshakeWith(remoteAddress))) // TODO nicer API
        sleep(1) // we give it some time to keep failing to connect, so the second node is not yet started
        setUpRemote()

        try assertAssociated(system: local, expectAssociatedAddress: self.remoteUniqueAddress)
        try assertAssociated(system: remote, expectAssociatedAddress: self.localUniqueAddress)
    }

    func test_association_shouldNotAssociateWhenRejected() throws {
        setUpLocal {
            $0.cluster._protocolVersion.major += 1 // handshake will be rejected on major version difference
        }
        setUpRemote()

        local.remoting.tell(.command(.handshakeWith(self.remoteUniqueAddress.address))) // TODO nicer API

        try assertNotAssociated(system: local, expectAssociatedAddress: self.remoteUniqueAddress)
        try assertNotAssociated(system: remote, expectAssociatedAddress: self.localUniqueAddress)
    }
}
