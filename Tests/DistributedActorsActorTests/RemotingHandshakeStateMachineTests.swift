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
import NIO

class RemotingHandshakeStateMachineTests: XCTestCase {

    typealias HSM = HandshakeStateMachine

    let systemName = "RemotingHandshakeTests"

    // usual reminder that Swift Distributed Actors is not inherently "client/server" once associated, only the handshake is
    enum HandshakeSide: String {
        case client
        case server
    }

    func makeMockKernelState(side: HandshakeSide, configureSettings: (inout RemotingSettings) -> () = { _ in () }) -> KernelState {
        var settings = RemotingSettings(bindAddress: NodeAddress(systemName: systemName, host: "127.0.0.1", port: 7337))
        configureSettings(&settings)
        let log = Logging.make("handshake-\(side)") // TODO could be a mock logger we can assert on?

        return KernelState(settings: settings, channel: EmbeddedChannel(), log: log)
    }
    

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path handshakes

    func test_handshake_happyPath() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.boundAddress

        let clientKernel = self.makeMockKernelState(side: .client) { settings  in
            settings.bindAddress.port = 2222
        }

        // client
        let clientInitiated = HSM.initialClientState(kernelState: clientKernel, connectTo: serverAddress.address)
        let offer: Wire.HandshakeOffer = clientInitiated.makeOffer()

        // server
        let received = HSM.initialServerState(kernelState: serverKernel, offer: offer)
        received._makeCompletedState() // TODO hide this

        let serverCompleted: HSM.CompletedState
        switch received.negotiate() {
        case .acceptAndAssociate(let completed):
            serverCompleted = completed
        case .rejectHandshake:
            throw shouldNotHappen("Must not reject the handshake")
        case .goAwayRogueHandshake:
            throw shouldNotHappen("Must not goaway the handshake")
        }

        let serverAccepted = serverCompleted.makeAccept()

        // client
        let clientCompleted = HSM.CompletedState(fromInitiated: clientInitiated, remoteAddress: serverAccepted.from)

        // then

        serverCompleted.boundAddress.shouldEqual(serverKernel.boundAddress)
        serverCompleted.remoteAddress.shouldEqual(clientKernel.boundAddress)

        clientCompleted.remoteAddress.shouldEqual(serverKernel.boundAddress)
        clientCompleted.boundAddress.shouldEqual(clientKernel.boundAddress)
    }


    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Version negotiation

    func test_negotiate_server_shouldAcceptClient_newerPatch() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.boundAddress

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.bindAddress.port = 2222
            settings._protocolVersion.patch += 1
        }

        // client
        let clientInitiated = HSM.initialClientState(kernelState: clientKernel, connectTo: serverAddress.address)
        let offer: Wire.HandshakeOffer = clientInitiated.makeOffer()

        // server
        let received = HSM.initialServerState(kernelState: serverKernel, offer: offer)

        // then

        let serverCompleted: HSM.CompletedState
        switch received.negotiate() {
        case .acceptAndAssociate(let completed):
            serverCompleted = completed
        case .rejectHandshake:
            throw shouldNotHappen("Must not reject the handshake")
        case .goAwayRogueHandshake:
            throw shouldNotHappen("Must not goaway the handshake")
        }

        _ = serverCompleted.makeAccept()
    }

    func test_negotiate_server_shouldRejectClient_newerMajor() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.boundAddress

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.bindAddress.port = 2222
            settings._protocolVersion.major += 1
        }

        pprint("server = \(serverKernel.settings.protocolVersion)")
        pprint("client = \(clientKernel.settings.protocolVersion)")


        // client
        let clientInitiated = HSM.initialClientState(kernelState: clientKernel, connectTo: serverAddress.address)
        let offer: Wire.HandshakeOffer = clientInitiated.makeOffer()

        // server
        let received = HSM.initialServerState(kernelState: serverKernel, offer: offer)

        // then

        let error: Error
        switch received.negotiate() {
        case .acceptAndAssociate(let completed):
            throw shouldNotHappen("Must not accept handshake from such much more new-er node; \(completed)")
        case .goAwayRogueHandshake:
            throw shouldNotHappen("Must not goaway the handshake")
        case .rejectHandshake(let e):
            error = e
        }

        pinfo("ERROR: \(error)")
    }


}
