//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import Foundation
import XCTest

@testable import DistributedCluster

final class NodeDeathWatcherTests: ClusteredActorSystemsXCTestCase {
    func test_nodeDeath_shouldFailAllRefsOnSpecificAddress() async throws {
        let first = await setUpNode("first") { settings in
            settings.swim.probeInterval = .milliseconds(100)
        }
        let second = await setUpNode("second") { settings in
            settings.swim.probeInterval = .milliseconds(100)
        }

        try await self.joinNodes(node: first, with: second)

        let refOnRemote1: _ActorRef<String> = try second._spawn("remote-1", .ignore)
        let refOnFirstToRemote1 = first._resolve(ref: refOnRemote1, onSystem: second)

        let refOnRemote2: _ActorRef<String> = try second._spawn("remote-2", .ignore)
        let refOnFirstToRemote2 = first._resolve(ref: refOnRemote2, onSystem: second)

        let testKit = ActorTestKit(first)
        let p = testKit.makeTestProbe(expecting: _Signals.Terminated.self)

        // --- prepare actor on [first], which watches remote actors ---

        _ = try first._spawn(
            "watcher1",
            _Behavior<String>.setup { context in
                context.watch(refOnFirstToRemote1)
                context.watch(refOnFirstToRemote2)

                let recv: _Behavior<String> = .receiveMessage { _ in
                    .same
                }

                return recv.receiveSpecificSignal(_Signals.Terminated.self) { _, terminated in
                    p.ref.tell(terminated)
                    return .same
                }
            }
        )

        try await self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node)
        first.cluster.down(endpoint: second.cluster.node.endpoint)

        // should cause termination of all remote actors, observed by the local actors on [first]
        let termination1: _Signals.Terminated = try p.expectMessage()
        let termination2: _Signals.Terminated = try p.expectMessage()
        let terminations: [_Signals.Terminated] = [termination1, termination2]
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.id.name == "remote-1"
        })
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.id.name == "remote-2"
        })

        // should not trigger terminated again for any of the remote refs
        first.cluster.down(endpoint: second.cluster.node.endpoint)
        try p.expectNoMessage(for: .milliseconds(50))
    }
}
