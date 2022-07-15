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

public protocol ClusterSingletonProtocol: DistributedActor where ActorSystem == ClusterSystem {
    /// The singleton should no longer be active on this cluster member.
    ///
    /// Invoked by the cluster singleton manager when it is determined that this member should no longer
    /// be hosting this singleton instance. The singleton upon receiving this call, should either cease activity,
    /// or take steps to terminate itself entirely.
    func passivateSingleton() async
}

extension ClusterSingletonProtocol {
    public func passivateSingleton() async {
        // nothing by default
    }
}

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

    public func proxy<Act>(
        _ type: Act.Type,
        name: String,
        settings: ClusterSingletonSettings = .init()
    ) async throws -> Act where Act: ClusterSingletonProtocol {
        var settings = settings
        settings.name = name
        return try await self.proxy(type, settings: settings, system: self.actorSystem, makeInstance: nil)
    }

    /// Configures the singleton plugin to host instances of this actor.
    public func host<Act>(
        _ type: Act.Type = Act.self,
        name: String,
        settings: ClusterSingletonSettings = .init(),
        makeInstance factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act where Act: ClusterSingletonProtocol {
        var settings = settings
        settings.name = name
        return try await self.proxy(type, settings: settings, system: self.actorSystem, makeInstance: factory)
    }

    internal func proxy<Act>(
        _ type: Act.Type,
        settings: ClusterSingletonSettings,
        system: ClusterSystem,
        makeInstance factory: ((ClusterSystem) async throws -> Act)?
    ) async throws -> Act where Act: ClusterSingletonProtocol {
        let key = settings.name.isEmpty ? "\(type)" : settings.name
        let known = self.singletons[key]
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

        self.singletons[key] = (proxied.id, boss)
        return proxied
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
