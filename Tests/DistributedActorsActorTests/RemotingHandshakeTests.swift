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

class RemotingHandshakeTests: XCTestCase {

    func makeInitialState() -> HandshakeStateMachine.InitiatedState {
        let log = Logging.make("RemotingHandshakeTests")
        let settings = RemotingSettings(bindAddress: NodeAddress(systemName: "RemotingHandshakeTests", host: "127.0.0.1", port: 1337))
        let remoteAddress = NodeAddress(systemName: "RemotingHandshakeTests", host: "127.0.0.1", port: 7331)
        let kernelState = KernelState(settings: settings, channel: EmbeddedChannel(), log: log)

        return HandshakeStateMachine.InitiatedState(kernelState: kernelState, remoteAddress: remoteAddress)
    }

    func test_handshakeStateMachine_inIsolationHere() throws {
        let initial = self.makeInitialState()

        // TODO: more tests
    }

}
