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

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ClusterSingletonPluginTests: ClusterSystemXCTestCase {
    func test_singletonPlugin_clusterDisabled() async throws {
        // Singleton should work just fine without clustering
        let test = await setUpNode("test") { settings in
            settings.enabled = false
            settings += ClusterSingletonPlugin()
        }

        // singleton.host
        let ref = try await test.singleton.host(of: TheSingleton.self, name: TheSingleton.name) { actorSystem in
            TheSingleton(greeting: "Hello", actorSystem: actorSystem)
        }
        let reply = try await ref.greet(name: "Charlie")
        reply.shouldStartWith(prefix: "Hello Charlie!")

        // singleton.ref (proxy-only)
        let proxyRef = try await test.singleton.proxy(of: TheSingleton.self, name: TheSingleton.name)
        let proxyReply = try await proxyRef.greet(name: "Charlene")
        proxyReply.shouldStartWith(prefix: "Hello Charlene!")
    }
}
