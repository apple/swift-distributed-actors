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

import Distributed

public protocol ClusterSingletonProtocol: DistributedActor where ActorSystem == ClusterSystem {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton plugin

/// `ClusterSingletonPlugin` ensures that there is no more than one instance of a distributed actor running in the cluster.
///
/// A singleton may run on any node in the cluster. Use `ClusterSingletonSettings.allocationStrategy` to control
/// its allocation. On candidate nodes where the singleton might run, use `ClusterSystem.singleton.host(type:name:factory:)`
/// to define the cluster singleton. Otherwise, call `ClusterSystem.singleton.proxy(type:name)` to obtain the singleton. The returned
/// `DistributedActor` is a proxy that can handle situations where the singleton might get relocated to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///            the singleton allocation.
/// - SeeAlso: The `ClusterSingleton` mechanism is conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
///            and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public actor ClusterSingletonPlugin {
    private var singletons: [String: (proxyID: ActorID, boss: any ClusterSingletonBossProtocol)] = [:]

    private var system: ClusterSystem!

    public func proxy<Act>(
        of type: Act.Type,
        name: String
    ) async throws -> Act
        where Act: ClusterSingletonProtocol
    {
        let settings = ClusterSingletonSettings(name: name)
        return try await self.proxy(of: type, settings: settings, makeInstance: nil)
    }

    public func proxy<Act>(
        of type: Act.Type,
        settings: ClusterSingletonSettings,
        makeInstance factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: ClusterSingletonProtocol,
        Act.ActorSystem == ClusterSystem
    {
        let known = self.singletons[settings.name]
        if let existingID = known?.proxyID {
            return try Act.resolve(id: existingID, using: self.system)
        }

        // Spawn the singleton boss (one per singleton per node)
        let boss = try await ClusterSingletonBoss(
            settings: settings,
            system: self.system,
            factory
        )

        let interceptor = ClusterSingletonRemoteCallInterceptor(system: self.system, singletonBoss: boss)
        let proxied = try self.system.interceptCalls(to: type, metadata: ActorMetadata(), interceptor: interceptor)

        self.singletons[settings.name] = (proxied.id, boss)

        return proxied
    }

    public func host<Act>(
        of type: Act.Type = Act.self,
        name: String,
        makeInstance factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: ClusterSingletonProtocol
    {
        let settings = ClusterSingletonSettings(name: name)
        return try await self.host(of: type, settings: settings, makeInstance: factory)
    }

    public func host<Act>(
        of type: Act.Type = Act.self,
        settings: ClusterSingletonSettings,
        makeInstance factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: ClusterSingletonProtocol
    {
        try await self.proxy(of: type, settings: settings, makeInstance: factory)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ClusterSingletonPlugin: _Plugin {
    static let pluginKey = _PluginKey<ClusterSingletonPlugin>(plugin: "$clusterSingleton")

    public nonisolated var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ClusterSystem) async throws {
        self.system = system
    }

    public func stop(_ system: ClusterSystem) async {
        for (_, (_, boss)) in self.singletons {
            await boss.stop()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton refs and actors

extension ClusterSystem {
    public var singleton: ClusterSingletonPlugin {
        let key = ClusterSingletonPlugin.pluginKey
        guard let singletonPlugin = self.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.settings.plugins)")
        }
        return singletonPlugin
    }
}
