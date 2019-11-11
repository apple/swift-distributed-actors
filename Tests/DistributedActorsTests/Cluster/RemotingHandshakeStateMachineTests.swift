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
import DistributedActorsTestTools
import Foundation
import Logging
import NIO
import XCTest

final class RemoteHandshakeStateMachineTests: XCTestCase {
    typealias HSM = HandshakeStateMachine

    let systemName = "RemoteHandshakeStateMachineTests"

    // usual reminder that Swift Distributed Actors is not inherently "client/server" once associated, only the handshake is
    enum HandshakeSide: String {
        case client
        case server
    }

    func makeMockKernelState(side: HandshakeSide, configureSettings: (inout ClusterSettings) -> Void = { _ in () }) -> ClusterShellState {
        var settings = ClusterSettings(
            node: Node(
                systemName: systemName,
                host: "127.0.0.1",
                port: 7337
            )
        )
        configureSettings(&settings)
        let log = Logger(label: "handshake-\(side)") // TODO: could be a mock logger we can assert on?

        return ClusterShellState(
            settings: settings,
            channel: EmbeddedChannel(),
            events: EventStream(ref: ActorRef(.deadLetters(.init(log, address: ._deadLetters, system: nil)))),
            gossip: PeriodicBroadcastControl(ActorRef(.deadLetters(.init(log, address: ._deadLetters, system: nil)))),
            log: log
        )
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Happy path handshakes

    func test_handshake_happyPath() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.selfNode

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.node.port = 2222
        }

        // client
        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.selfNode, connectTo: serverAddress.node, whenCompleted: nil)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeReceivedState(state: serverKernel, offer: offer, whenCompleted: nil) // TODO: test that it completes?
        _ = received._acceptAndMakeCompletedState() // TODO: hide this

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

        serverCompleted.localNode.shouldEqual(serverKernel.selfNode)
        serverCompleted.remoteNode.shouldEqual(clientKernel.selfNode)

        clientCompleted.remoteNode.shouldEqual(serverKernel.selfNode)
        clientCompleted.localNode.shouldEqual(clientKernel.selfNode)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Version negotiation

    func test_negotiate_server_shouldAcceptClient_newerPatch() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.selfNode

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.node.port = 2222
            settings._protocolVersion.patch += 1
        }

        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.selfNode, connectTo: serverAddress.node, whenCompleted: nil)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeReceivedState(state: serverKernel, offer: offer, whenCompleted: nil) // TODO: test that it completes?

        // then

        switch received.negotiate() {
        case .acceptAndAssociate:
            ()
        case .rejectHandshake:
            throw shouldNotHappen("Must not reject the handshake")
        }
    }

    func test_negotiate_server_shouldRejectClient_newerMajor() throws {
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.selfNode

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.node.port = 2222
            settings._protocolVersion.major += 1
        }

        let clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.selfNode, connectTo: serverAddress.node, whenCompleted: nil)
        let offer = clientInitiated.makeOffer()

        // server
        let received = HSM.HandshakeReceivedState(state: serverKernel, offer: offer, whenCompleted: nil) // TODO: test that it completes?

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
        let serverKernel = self.makeMockKernelState(side: .server)
        let serverAddress = serverKernel.selfNode

        let clientKernel = self.makeMockKernelState(side: .client) { settings in
            settings.node.port = 8228
        }

        // client
        var clientInitiated = HSM.InitiatedState(settings: clientKernel.settings, localNode: clientKernel.selfNode, connectTo: serverAddress.node, whenCompleted: nil)

        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeTimeout() else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeTimeout() else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
        guard case .scheduleRetryHandshake = clientInitiated.onHandshakeError(TestError("Boom!")) else {
            throw shouldNotHappen("Expected retry attempt after handshake timeout")
        }
    }
}
