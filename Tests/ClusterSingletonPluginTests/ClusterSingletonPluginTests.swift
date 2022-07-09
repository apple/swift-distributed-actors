//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import ClusterSingletonPlugin
import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ClusterSingletonPluginTests: ClusterSystemXCTestCase {
    func test_noCluster_ref() async throws {
        // Singleton should work just fine without clustering
        let system = await setUpNode("test") { settings in
            settings.enabled = false
            settings += ActorSingletonPlugin()
        }
        let replyProbe = ActorTestKit(system).makeTestProbe(expecting: String.self)

        // singleton.host behavior
        let ref = try system.singleton.host(GreeterSingleton.Message.self, name: GreeterSingleton.name, GreeterSingleton("Hello").behavior)
        ref.tell(.greet(name: "Charlie", replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlie!")

        // singleton.ref (proxy-only)
        let proxyRef = try system.singleton.ref(of: GreeterSingleton.Message.self, name: GreeterSingleton.name)
        proxyRef.tell(.greet(name: "Charlene", replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlene!")
    }
}
