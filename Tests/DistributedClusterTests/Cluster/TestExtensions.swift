//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedCluster
import Logging
import NIO

// usual reminder that Swift Distributed Actors is not inherently "client/server" once associated, only the handshake is
enum HandshakeSide: String {
    case client
    case server
}

extension ClusterShellState {
    static func makeTestMock(side: HandshakeSide, configureSettings: (inout ClusterSystemSettings) -> Void = { _ in () }) -> ClusterShellState {
        var settings = ClusterSystemSettings(
            node: Node(
                systemName: "MockSystem",
                host: "127.0.0.1",
                port: 7337
            )
        )
        configureSettings(&settings)
        let log = Logger(label: "handshake-\(side)") // TODO: could be a mock logger we can assert on?

        let node: UniqueNode = .init(systemName: "Test", host: "127.0.0.1", port: 7337, nid: .random())
        return ClusterShellState(
            settings: settings,
            channel: EmbeddedChannel(),
            events: ClusterEventStream(), // this event stream does nothing
            gossiperControl: GossiperControl(_ActorRef(.deadLetters(.init(log, id: ._deadLetters(on: node), system: nil)))),
            log: log
        )
    }
}
