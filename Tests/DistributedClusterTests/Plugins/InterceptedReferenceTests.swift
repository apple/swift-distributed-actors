//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
import Foundation
import XCTest

@testable import DistributedCluster

final class InterceptedReferenceTests: ClusteredActorSystemsXCTestCase {
    func test_interceptedReference_deliversCallsThroughItsInterceptor() async throws {
        let routes = RoutingPlugin()
        let node = await self.setUpNode("node") { settings in
            settings += routes
        }
        let greeter = RoutedGreeter(greeting: "hi", actorSystem: node)
        routes.route("greeter", to: greeter.id)

        let reference = try routes.reference(RoutedGreeter.self, routedTo: "greeter")

        let greeting = try await reference.greet()
        greeting.shouldEqual("hi")
        try await reference.remember("noted")
        let remembered = try await greeter.remembered()
        remembered.shouldEqual(["noted"])
    }

    func test_interceptedReference_sentToAnotherNode_isInterceptedThere() async throws {
        let firstRoutes = RoutingPlugin()
        let secondRoutes = RoutingPlugin()
        let first = await self.setUpNode("first") { settings in
            settings.propagateMetadata(\.route)
            settings += firstRoutes
        }
        let second = await self.setUpNode("second") { settings in
            settings.propagateMetadata(\.route)
            settings += secondRoutes
        }
        first.cluster.join(endpoint: second.cluster.node.endpoint)
        try await self.ensureNodes(.up, on: first, within: .seconds(10), nodes: second.cluster.node)

        let v1 = RoutedGreeter(greeting: "v1", actorSystem: first)
        firstRoutes.route("greeter", to: v1.id)
        secondRoutes.route("greeter", to: v1.id)

        // The reference is sent to `second`, which keeps it and calls it from there.
        let reference = try firstRoutes.reference(RoutedGreeter.self, routedTo: "greeter")
        let keeper = RoutedGreeterKeeper(actorSystem: second)
        let remoteKeeper = try RoutedGreeterKeeper.resolve(id: keeper.id, using: first)
        try await remoteKeeper.keep(reference)
        let keptGreeting = try await remoteKeeper.greetKept()
        keptGreeting.shouldEqual("v1")

        // The route changes; the reference both nodes hold now reaches the new actor.
        let v2 = RoutedGreeter(greeting: "v2", actorSystem: second)
        firstRoutes.route("greeter", to: v2.id)
        secondRoutes.route("greeter", to: v2.id)
        let keptGreetingAfter = try await remoteKeeper.greetKept()
        keptGreetingAfter.shouldEqual("v2")
        let greetingAfter = try await reference.greet()
        greetingAfter.shouldEqual("v2")
    }

    func test_interceptedReference_sentToNodeWithoutThePlugin_isNotInterceptedThere() async throws {
        let routes = RoutingPlugin()
        let first = await self.setUpNode("first") { settings in
            settings.propagateMetadata(\.route)
            settings += routes
            settings.remoteCall.defaultTimeout = .seconds(2)
        }
        let second = await self.setUpNode("second") { settings in
            settings.propagateMetadata(\.route)
            settings.remoteCall.defaultTimeout = .seconds(2)
        }
        first.cluster.join(endpoint: second.cluster.node.endpoint)
        try await self.ensureNodes(.up, on: first, within: .seconds(10), nodes: second.cluster.node)

        let greeter = RoutedGreeter(greeting: "hi", actorSystem: first)
        routes.route("greeter", to: greeter.id)
        let reference = try routes.reference(RoutedGreeter.self, routedTo: "greeter")
        let keeper = RoutedGreeterKeeper(actorSystem: second)
        let remoteKeeper = try RoutedGreeterKeeper.resolve(id: keeper.id, using: first)
        try await remoteKeeper.keep(reference)

        _ = try await shouldThrow {
            try await remoteKeeper.greetKept()
        }
    }
}

extension ActorMetadataKeys {
    var route: Key<String> { "route" }
}

/// Makes references routed by name, and intercepts calls to them on every node it's installed on.
private final class RoutingPlugin: ActorLifecyclePlugin, @unchecked Sendable {
    static let pluginKey: Key = "$routing"

    var key: Key { Self.pluginKey }

    private let lock = NSLock()
    private var routes: [String: ClusterSystem.ActorID] = [:]
    private var system: ClusterSystem?

    func route(_ name: String, to id: ClusterSystem.ActorID) {
        self.lock.withLock { self.routes[name] = id }
    }

    func reference<Act>(_ type: Act.Type, routedTo name: String) throws -> Act
    where Act: DistributedActor, Act.ActorSystem == ClusterSystem {
        let metadata = ActorMetadata()
        metadata.route = name
        return try self.lock.withLock { self.system! }
            .interceptCalls(to: type, metadata: metadata, interceptor: RoutingInterceptor(plugin: self, name: name))
    }

    func onActorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {}

    func onResignID(_ id: ClusterSystem.ActorID) {}

    func interceptor(for id: ActorID) -> (any RemoteCallInterceptor)? {
        id.metadata.route.map { RoutingInterceptor(plugin: self, name: $0) }
    }

    func destination(of name: String) throws -> (ClusterSystem, ClusterSystem.ActorID) {
        try self.lock.withLock {
            guard let system = self.system, let id = self.routes[name] else { throw UnknownRoute(name: name) }
            return (system, id)
        }
    }

    func start(_ system: ClusterSystem) async throws {
        self.lock.withLock { self.system = system }
    }

    func stop(_ system: ClusterSystem) async {
        self.lock.withLock { self.system = nil }
    }
}

private struct RoutingInterceptor: RemoteCallInterceptor {
    let plugin: RoutingPlugin
    let name: String

    func interceptRemoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        let (system, id) = try self.plugin.destination(of: self.name)
        return try await system.forwardCall(to: id, target: target, invocation: &invocation, throwing: throwing, returning: returning)
    }

    func interceptRemoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        let (system, id) = try self.plugin.destination(of: self.name)
        try await system.forwardCallVoid(to: id, target: target, invocation: &invocation, throwing: throwing)
    }
}

private struct UnknownRoute: Error {
    let name: String
}

distributed actor RoutedGreeter {
    typealias ActorSystem = ClusterSystem

    let greeting: String
    var notes: [String] = []

    init(greeting: String, actorSystem: ActorSystem) {
        self.greeting = greeting
        self.actorSystem = actorSystem
    }

    distributed func greet() -> String {
        self.greeting
    }

    distributed func remember(_ note: String) {
        self.notes.append(note)
    }

    distributed func remembered() -> [String] {
        self.notes
    }
}

distributed actor RoutedGreeterKeeper {
    typealias ActorSystem = ClusterSystem

    var kept: RoutedGreeter?

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    distributed func keep(_ greeter: RoutedGreeter) {
        self.kept = greeter
    }

    distributed func greetKept() async throws -> String {
        try await self.kept!.greet()
    }
}
