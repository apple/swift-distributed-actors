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

import DistributedActorsTestKit
@testable import DistributedCluster
import Testing

@Suite(.serialized)
final class ClusterSingletonPluginTests: SingleClusterSystemXCTestCase {
    
    @Test
    func test_singletonPlugin_clusterDisabled() async throws {
        // Singleton should work just fine without clustering
        let test = await setUpNode("test") { settings in
            settings.enabled = false
            settings += ClusterSingletonPlugin()
        }

        let name = "the-one"

        // singleton.host
        let ref = try await test.singleton.host(name: name) { actorSystem in
            TheSingleton(greeting: "Hello", actorSystem: actorSystem)
        }
        let reply = try await ref.greet(name: "Charlie")
        reply.shouldStartWith(prefix: "Hello Charlie!")

        // singleton.ref (proxy-only)
        let proxyRef = try await test.singleton.proxy(TheSingleton.self, name: name)
        let proxyReply = try await proxyRef.greet(name: "Charlene")
        proxyReply.shouldStartWith(prefix: "Hello Charlene!")
    }

    @Test
    func test_singleton_nestedSingleton() async throws {
        let system = await setUpNode("test") { settings in
            settings += ClusterSingletonPlugin()
        }

        let singleton = try await system.singleton.host(name: "test-singleton") { actorSystem in
            SingletonWhichCreatesDistributedActorDuringInit(actorSystem: actorSystem)
        }

        let singletonID = singleton.id
        let greeterID = try await singleton.getGreeter().id

        pinfo("singleton proxy    id: \(singletonID)")
        pinfo("singleton actual   id: \(try await singleton.actualID())")
        pinfo("singleton(greeter) id: \(greeterID)")

        try await singleton.actualID().detailedDescription.shouldContain("test-singleton")
        // if this were true we would have crashed by a duplicate name already, but let's make sure:
        singletonID.shouldNotEqual(greeterID)
    }

    distributed actor SingletonWhichCreatesDistributedActorDuringInit: ClusterSingleton {
        typealias ActorSystem = ClusterSystem

        private let greeter: Greeter

        init(actorSystem: ActorSystem) {
            self.actorSystem = actorSystem
            self.greeter = Greeter(actorSystem: actorSystem)
        }

        distributed func actualID() -> ActorSystem.ActorID {
            self.id
        }

        distributed func getGreeter() -> Greeter {
            return self.greeter
        }
    }

    distributed actor Greeter {
        typealias ActorSystem = ClusterSystem
        init(actorSystem: ActorSystem) {
            self.actorSystem = actorSystem
        }

        distributed func greet() {
            print("Hello!")
        }
    }
}
