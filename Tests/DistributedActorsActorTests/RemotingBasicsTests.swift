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

class RemotingBasicsTests: XCTestCase {

    func test_bindOnStartup_shouldStartNetworkActorUnderSystemProvider() throws {
        let system = ActorSystem("RemotingBasicsTests") { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress = NodeAddress(systemName: "RemotingBasicsTests", host: "127.0.0.1", port: 8338)
        }
        defer { system.terminate() }

        let testKit = ActorTestKit(system)

        try testKit.eventually(within: .seconds(1)) {
            try testKit._assertActorPathOccupied("/system/remoting")
        }
    }

    func test_boundServer_shouldAcceptAssociate() throws {
        let system = ActorSystem("2RemotingBasicsTests") { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress = NodeAddress(systemName: "2RemotingBasicsTests", host: "127.0.0.1", port: 8448)
        }
        defer { system.terminate() }
        let testKit = ActorTestKit(system)

        let remote = ActorSystem("2RemotingBasicsTests") { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress = NodeAddress(systemName: "2RemotingBasicsTests", host: "127.0.0.1", port: 9559)
        }
        let remoteNodeAddress: NodeAddress = remote.settings.remoting.bindAddress
        defer { remote.terminate() }

        system.remoting.tell(.command(.handshakeWith(remoteNodeAddress))) // TODO nicer API

        sleep(2) // TODO make this test actually test associations :)

        let probe = testKit.spawnTestProbe(expecting: [UniqueNodeAddress].self)
        try testKit.eventually(within: .milliseconds(500)) {
            system.remoting.tell(.query(.associatedNodes(probe.ref))) // FIXME: We need to get the Accept back and act on it on the origin side
            let associatedNodes = try probe.expectMessage()
            associatedNodes.shouldBeNotEmpty() // means we have associated to _someone_
        }
        let remoteProbe = testKit.spawnTestProbe(expecting: [UniqueNodeAddress].self)
        try testKit.eventually(within: .milliseconds(500)) {
            remote.remoting.tell(.query(.associatedNodes(remoteProbe.ref)))
            let associatedNodes = try remoteProbe.expectMessage()
            associatedNodes.shouldBeNotEmpty() // means we have associated to _someone_
        }
    }

    // TODO: make sure to test also for what happens for `connection refused`.
    // Fatal error: 'try!' expression unexpectedly raised an error: NIO.ChannelError.connectFailed(NIO.NIOConnectionError(host: "127.0.0.1", port: 9559, dnsAError: nil, dnsAAAAError: nil, connectionErrors: [NIO.SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:9559, error: connection reset (error set): Connection refused (errno: 61))])): file /Users/buildnode/jenkins/workspace/oss-swift-4.2-package-osx/swift/stdlib/public/core/ErrorType.swift, line 184



}
