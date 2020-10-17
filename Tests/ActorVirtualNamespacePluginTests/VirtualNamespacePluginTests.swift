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

@testable import ActorVirtualNamespacePlugin
import DistributedActors
import DistributedActorsTestKit
import XCTest

final class VirtualNamespacePluginTests: ActorSystemXCTestCase {
    func test_noCluster_ref() throws {
        // Singleton should work just fine without clustering
        let system = ActorSystem("test") { settings in
            settings.cluster.enabled = false
            settings += VirtualNamespacePlugin()
        }

        defer {
            try! system.shutdown().wait()
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

}
