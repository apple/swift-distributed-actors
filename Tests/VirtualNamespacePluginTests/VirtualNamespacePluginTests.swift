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
import XCTest
import VirtualNamespacePlugin

final class VirtualNamespacePluginTests: ActorSystemXCTestCase {

    func test_noCluster_ref() throws {
        let system = self.setUpNode("test") { settings in
            settings.cluster.enabled = false
            settings += VirtualNamespacePlugin()
        }

        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)

        let ref = try system.virtual.ref("caplin-the-capybara", TestVirtualActor.behavior)
        ref.tell(.hello(replyTo: replyProbe.ref))

        try replyProbe.expectMessage("Hello!")
    }
}

enum TestVirtualActor {
    enum Message: NonTransportableActorMessage {
        case hello(replyTo: ActorRef<String>)
    }

    static var behavior: Behavior<Message> {
        .receive { context, message in
            switch message {
            case .hello(let replyTo):
                replyTo.tell("Hello!")
            }
            return .same
        }
    }
}
