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

    private var actorSystem: ClusterSystem!

    public init() {
        self.actorSystem = nil // 'actorSystem' is filled in later on in Plugin.start()
    }

    public func proxy<Act>(
        _ type: Act.Type,
        name: String,
        settings: ClusterSingletonSettings = .init()
    ) async throws -> Act where Act: ClusterSingleton {
        var settings = settings
        settings.name = name
        return try await self._get(type, settings: settings, system: self.actorSystem, makeInstance: nil)
    }

    /// Configures the singleton plugin to host instances of this actor.
    public func host<Act>(
        _ type: Act.Type = Act.self,
        name: String,
        settings: ClusterSingletonSettings = .init(),
        makeInstance factory: (@Sendable (ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act where Act: ClusterSingleton {
        var settings = settings
        settings.name = name
        return try await self._get(type, settings: settings, system: self.actorSystem, makeInstance: factory)
    }

    internal func _get<Act>(
        _ type: Act.Type,
        settings: ClusterSingletonSettings,
        system: ClusterSystem,
        makeInstance factory: (@Sendable (ClusterSystem) async throws -> Act)?
    ) async throws -> Act where Act: ClusterSingleton {
        let singletonName = settings.name
        guard !singletonName.isEmpty else {
            fatalError("ClusterSingleton \(Act.self) must have specified unique name!")
        }

        let known = self.singletons[singletonName]
        if let existingID = known?.proxyID {
            return try Act.resolve(id: existingID, using: system)
        }

        // Spawn the singleton boss (one per singleton per node)
        let boss = try await ClusterSingletonBoss(
            settings: settings,
            system: system,
            factory
        )
        let interceptor = ClusterSingletonRemoteCallInterceptor(system: system, singletonBoss: boss)
        let proxied = try system.interceptCalls(to: type, metadata: ActorMetadata(), interceptor: interceptor)

        self.singletons[singletonName] = (proxied.id, boss)
        return proxied
    }

    // FOR TESTING
    internal func _boss<Singleton: ClusterSingleton>(name: String, type: Singleton.Type = Singleton.self) -> ClusterSingletonBoss<Singleton>? {
        guard let (_, boss) = self.singletons[name] else {
            return nil
        }

        return boss as? ClusterSingletonBoss<Singleton>
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ClusterSingletonPlugin: Plugin {
    static let pluginKey: Key = "$clusterSingleton"

    public nonisolated var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ClusterSystem) async throws {
        self.actorSystem = system
    }

    public func stop(_ system: ClusterSystem) async {
        self.actorSystem = nil
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
