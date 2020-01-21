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

@testable import ActorSingletonPlugin
import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ActorSingletonPluginTests: ActorSystemTestBase {
    func test_ClusterSingleton_shouldWorkWithoutCluster() throws {
        // Singleton should work just fine without clustering
        let system = ActorSystem("test") { settings in
            settings.cluster.enabled = false
            settings += ActorSingleton(GreeterSingleton.name, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello")))
            settings += ActorSingleton("\(GreeterSingleton.name)-other", GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hi")))
        }

        defer {
            system.shutdown().wait()
        }

        // singleton.ref
        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)
        let ref = try system.singleton.ref(name: GreeterSingleton.name, of: GreeterSingleton.Message.self)

        ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlie!")

        // singleton.actor
        let actor = try system.singleton.actor(name: "\(GreeterSingleton.name)-other", GreeterSingleton.self)
        // TODO: https://github.com/apple/swift-distributed-actors/issues/344
        // let string = try probe.expectReply(actor.greet(name: "Charlie", _replyTo: replyProbe.ref))
        actor.ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))

        try replyProbe.expectMessage("Hi Charlie!")
    }
}
