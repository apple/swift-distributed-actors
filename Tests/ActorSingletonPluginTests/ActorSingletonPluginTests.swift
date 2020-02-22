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
    func test_noCluster_ref() throws {
        // Singleton should work just fine without clustering
        let system = ActorSystem("test") { settings in
            settings.cluster.enabled = false
            settings += ActorSingletonPlugin()
        }

        defer {
            system.shutdown().wait()
        }

        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)

        // singleton.host behavior
        let ref = try system.singleton.host(GreeterSingleton.Message.self, name: GreeterSingleton.name, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello")))
        ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlie!")

        // singleton.ref (proxy-only)
        let proxyRef = try system.singleton.ref(of: GreeterSingleton.Message.self, name: GreeterSingleton.name)
        proxyRef.tell(.greet(name: "Charlene", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlene!")
    }

    func test_noCluster_actor() throws {
        // Singleton should work just fine without clustering
        let system = ActorSystem("test") { settings in
            settings.cluster.enabled = false
            settings += ActorSingletonPlugin()
        }

        defer {
            system.shutdown().wait()
        }

        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)

        // singleton.host Actorable
        let actor = try system.singleton.host(GreeterSingleton.self, name: GreeterSingleton.name) { _ in GreeterSingleton("Hi") }
        // TODO: https://github.com/apple/swift-distributed-actors/issues/344
        // let string = try probe.expectReply(actor.greet(name: "Charlie", _replyTo: replyProbe.ref))
        actor.ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hi Charlie!")

        // singleton.actor (proxy-only)
        let actorProxy = try system.singleton.actor(of: GreeterSingleton.self, name: GreeterSingleton.name)
        actorProxy.ref.tell(.greet(name: "Charlene", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hi Charlene!")
    }
}
