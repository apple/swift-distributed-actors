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
import Logging
import NIO
import XCTest

final class RemoteHandshakeStateMachineTests: XCTestCase {
    typealias HSM = HandshakeStateMachine

    let systemName = "RemoteHandshakeStateMachineTests"

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path handshakes

    func test_handshake_happyPath() throws {
        let serverKernel = ClusterShellState.makeTestMock(side: .server)
        let serverAddress = serverKernel.localNode

        let clientKernel = ClusterShellState.makeTestMock(side: .client) { settings in
            settings.node.port = 2222
        }

        // client
        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.localNode, connectTo: serverAddress.node)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeOfferReceivedState(state: serverKernel, offer: offer) // TODO: test that it completes?

        let serverCompleted: HSM.CompletedState
        switch received.negotiate() {
        case .acceptAndAssociate(let completed):
            serverCompleted = completed
        case .rejectHandshake:
            throw shouldNotHappen("Must not reject the handshake")
        }

        // client
        let clientCompleted = HSM.CompletedState(fromInitiated: clientInitiated, remoteNode: serverAddress)

        // then

        serverCompleted.localNode.shouldEqual(serverKernel.localNode)
        serverCompleted.remoteNode.shouldEqual(clientKernel.localNode)

        clientCompleted.remoteNode.shouldEqual(serverKernel.localNode)
        clientCompleted.localNode.shouldEqual(clientKernel.localNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Version negotiation

    func test_negotiate_server_shouldAcceptClient_newerPatch() throws {
        let serverKernel = ClusterShellState.makeTestMock(side: .server)
        let serverAddress = serverKernel.localNode

        let clientKernel = ClusterShellState.makeTestMock(side: .client) { settings in
            settings.node.port = 2222
            settings._protocolVersion.patch += 1
        }

        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.localNode, connectTo: serverAddress.node)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeOfferReceivedState(state: serverKernel, offer: offer) // TODO: test that it completes?

        // then

        switch received.negotiate() {
        case .acceptAndAssociate:
            ()
        case .rejectHandshake:
            throw shouldNotHappen("Must not reject the handshake")
        }
    }

    func test_negotiate_server_shouldRejectClient_newerMajor() throws {
        let serverKernel = ClusterShellState.makeTestMock(side: .server)
        let serverAddress = serverKernel.localNode

        let clientKernel = ClusterShellState.makeTestMock(side: .client) { settings in
            settings.node.port = 2222
            settings._protocolVersion.major += 1
        }

        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.localNode, connectTo: serverAddress.node)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeOfferReceivedState(state: serverKernel, offer: offer) // TODO: test that it completes?

        // then

        let error: Error
        switch received.negotiate() {
        case .acceptAndAssociate(let completed):
            throw shouldNotHappen("Must not accept handshake from such much more new-er node; \(completed)")
        case .rejectHandshake(let rejected):
            error = rejected.error
        }

        "\(error)".shouldEqual("incompatibleProtocolVersion(local: Version(0.0.1, reserved:0), remote: Version(1.0.1, reserved:0))")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake timeout causing retries

    func test_onTimeout_shouldReturnNewHandshakeOffersMultipleTimes() throws {
        let serverKernel = ClusterShellState.makeTestMock(side: .server)
        let serverAddress = serverKernel.localNode

        let clientKernel = ClusterShellState.makeTestMock(side: .client) { settings in
            settings.node.port = 8228
        }

        // client
        var clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.localNode, connectTo: serverAddress.node)

        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeTimeout() else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeTimeout() else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeError(TestError("Boom!"), nil) else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
    }
}
