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
import XCTest

final class ClusterSingletonPluginTests: SingleClusterSystemXCTestCase {
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
    
    func test_plugin_hooks() async throws {
        let actorId = "actorHookId"
        let hookFulfillment = self.expectation(description: "actor-hook")
        let plugin = TestClusterHookPlugin { actor in
            /// There are multiple internal actors fired, we only checking for `ActorWithId`
            guard let actor = actor as? ActorWithId else { return }
            let id = try? await actor.getId()
            XCTAssertEqual(id, actorId, "Expected \(actorId) as an id")
            hookFulfillment.fulfill()
        }
        let testNode = await setUpNode("test-hook") { settings in
            settings.enabled = false
            settings += plugin
        }

        let _ = ActorWithId(actorSystem: testNode, id: actorId)
        await fulfillment(of: [hookFulfillment])
    }
    
    actor TestClusterHookPlugin: _Plugin, PluginActorLifecycleHook {
        nonisolated var key: Key { "$testClusterHook" }
        
        let onActorReady: (any DistributedActor) async throws -> ()
        
        init(
            onActorReady: @escaping (any DistributedActor) async throws -> Void
        ) {
            self.onActorReady = onActorReady
        }
        
        nonisolated func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == DistributedCluster.ClusterSystem.ActorID {
            Task { try await self.onActorReady(actor) }
        }
        
        nonisolated func resignID(_ id: DistributedCluster.ClusterSystem.ActorID) {
            
        }
        
        func start(_ system: ClusterSystem) async throws {}
        func stop(_ system: ClusterSystem) async {}
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
    
    distributed actor ActorWithId {
        let customId: String
        
        init(
            actorSystem: ActorSystem,
            id: String
        ) {
            self.actorSystem = actorSystem
            self.customId = id
        }
        
        distributed func getId() -> String { 
            self.customId
        }
    }
}
