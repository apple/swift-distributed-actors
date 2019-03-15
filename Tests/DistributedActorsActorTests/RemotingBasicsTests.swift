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
import NIOSSL


class RemotingBasicsTests: XCTestCase {

    var local: ActorSystem! = nil

    var remote: ActorSystem! = nil

    lazy var localUniqueAddress: UniqueNodeAddress = self.local.settings.remoting.uniqueBindAddress
    lazy var remoteUniqueAddress: UniqueNodeAddress = self.remote.settings.remoting.uniqueBindAddress

    override func setUp() {
        self.local = ActorSystem("2RemotingBasicsTests") { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress = NodeAddress(systemName: "2RemotingBasicsTests", host: "127.0.0.1", port: 8448)
        }
        self.remote = ActorSystem("2RemotingBasicsTests") { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress = NodeAddress(systemName: "2RemotingBasicsTests", host: "127.0.0.1", port: 9559)
        }
    }

    override func tearDown() {
        self.local.terminate()
        self.remote.terminate()
    }

    private func assertAssociated(system: ActorSystem, expectAssociatedAddress address: UniqueNodeAddress) throws {
        let testKit = ActorTestKit(system)
        let probe = testKit.spawnTestProbe(expecting: [UniqueNodeAddress].self)
        try testKit.eventually(within: .milliseconds(500)) {
            system.remoting.tell(.query(.associatedNodes(probe.ref)))
            let associatedNodes = try probe.expectMessage()
            pprint("                  Self: \(String(reflecting: system.settings.remoting.uniqueBindAddress))")
            pprint("      Associated nodes: \(associatedNodes)")
            pprint("         Expected node: \(String(reflecting: address))")
            associatedNodes.contains(address).shouldBeTrue() // TODO THIS SOMETIMES FAILS!!!!
        }
    }

    func test_boundServer_shouldAcceptAssociate() throws {
        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it
        try assertAssociated(system: local, expectAssociatedAddress: remoteUniqueAddress)
        try assertAssociated(system: remote, expectAssociatedAddress: localUniqueAddress)
    }

    func test_association_shouldAllowSendingToRemoteReference() throws {
        let remoteTestKit = ActorTestKit(remote)
        let probeOnRemote = remoteTestKit.spawnTestProbe(expecting: String.self)
        let refOnRemoteSystem: ActorRef<String> = try remote.spawn(.receiveMessage { message in
            probeOnRemote.tell("forwarded:\(message)")
            return .same
        }, name: "remoteAcquaintance")

        local.remoting.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(2) // TODO make it such that we don't need to sleep but assertions take care of it
        try assertAssociated(system: local, expectAssociatedAddress: remote.settings.remoting.uniqueBindAddress)

        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNodeAddress = remote.settings.remoting.uniqueBindAddress
        var uniqueRemotePath: UniqueActorPath = refOnRemoteSystem.path
        uniqueRemotePath.address = remoteNodeAddress // since refOnRemoteSystem is "local" there, it has no address; thus we set it
        // to then obtain a remote ref ON the `system`, meaning that the address within remotePath is a remote one
        let resolveContext = ResolveContext<String>(path: uniqueRemotePath, deadLetters: local.deadLetters)
        let resolvedRef = local._resolve(context: resolveContext)
        // the resolved ref is a local resource on the `system` and points via the right association to the remote actor
        // inside system `remote`. Sending messages to a ref constructed like this will make the messages go over remoting.
//        resolvedRef.tell("HELLO") // TODO: unlock with
//
//        try probeOnRemote.expectMessage("forwarded:HELLO") // TODO: unlock with
    }

    // TODO: make sure to test also for what happens for `connection refused`.
    // Fatal error: 'try!' expression unexpectedly raised an error: NIO.ChannelError.connectFailed(NIO.NIOConnectionError(host: "127.0.0.1", port: 9559, dnsAError: nil, dnsAAAAError: nil, connectionErrors: [NIO.SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:9559, error: connection reset (error set): Connection refused (errno: 61))])): file /Users/buildnode/jenkins/workspace/oss-swift-4.2-package-osx/swift/stdlib/public/core/ErrorType.swift, line 184
}
