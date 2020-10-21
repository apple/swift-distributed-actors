//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsTestKit
import VirtualNamespacePlugin
import XCTest

final class VirtualNamespacePluginTests: ClusteredActorSystemsXCTestCase {
    override var alwaysPrintCaptureLogs: Bool {
        true
    }

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster/gossip",
            "/system/replicator/gossip",
            "/system/cluster/leadership",
            "/system/cluster",
        ]
    }

    func test_noCluster_virtualRef() throws {
        let system = self.setUpNode("test") { settings in
            settings.cluster.enabled = false
            settings += VirtualNamespacePlugin(
                behavior: TestVirtualActor.behavior
            )
        }

        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)

        let ref = try system.virtual.ref("caplin-the-capybara", of: TestVirtualActor.Message.self)
        ref.tell(.hello(replyTo: replyProbe.ref))

        try replyProbe.expectMessage("Hello!")
    }

    func test_cluster_virtualRef() throws {
        let first = self.setUpNode("first") { settings in
            settings += VirtualNamespacePlugin(
                behavior: TestVirtualActor.behavior
            )
            settings.serialization.crashOnDeserializationFailure = true
        }
        let second = self.setUpNode("second") { settings in
            settings += VirtualNamespacePlugin(
                behavior: TestVirtualActor.behavior
            )
            settings.serialization.crashOnDeserializationFailure = true
        }
        let third = self.setUpNode("third") { settings in
            settings += VirtualNamespacePlugin(
                behavior: TestVirtualActor.behavior
            )
            settings.serialization.crashOnDeserializationFailure = true
        }

        second.cluster.join(node: first.cluster.uniqueNode)
        third.cluster.join(node: first.cluster.uniqueNode)

        sleep(5)

        let replyProbe = ActorTestKit(first).spawnTestProbe(expecting: String.self)

        let ref = try first.virtual.ref("caplin-the-capybara", of: TestVirtualActor.Message.self)
        ref.tell(.hello(replyTo: replyProbe.ref))

        try replyProbe.expectMessage("Hello!")
    }
}

enum TestVirtualActor {
    enum Message: NonTransportableActorMessage {
        case hello(replyTo: ActorRef<String>)
    }

    static var behavior: Behavior<Message> {
        .receive { _, message in
            switch message {
            case .hello(let replyTo):
                replyTo.tell("Hello!")
            }
            return .same
        }
    }
}
