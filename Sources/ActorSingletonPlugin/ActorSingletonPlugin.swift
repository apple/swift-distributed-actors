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
import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton plugin

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

/// The actor singleton plugin ensures that there is no more than one instance of an actor that is defined to be
/// singleton running in the cluster.
///
/// An actor singleton may run on any node in the cluster. Use `ActorSingletonSettings.allocationStrategy` to control
/// its allocation. On candidate nodes where the singleton might run, use `ClusterSystem.singleton.proxy(type:name:system:props:factory)`
/// to define the distributed actor. Otherwise, call `ClusterSystem.singleton.proxy(type:name:)` to obtain a distributed actor. The returned
/// `DistributedActor` is in reality a proxy that handles situations where the singleton might get relocated to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///            the singleton allocation.
/// - SeeAlso: The `ActorSingleton` mechanism is conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
///            and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public actor ActorSingletonPlugin {
    private var singletons: [String: (proxyID: ActorID, proxy: any AnyActorSingletonProxy)] = [:]

    private var actorSystem: ClusterSystem!
    
    public func proxy<Act>(
        _ type: Act.Type,
        name: String,
        settings: ActorSingletonSettings
    ) async throws -> Act where Act: ClusterSingletonProtocol
    {
        var settings = settings
        settings.name = name
        return try await self.proxy(type, settings: settings, system: self.actorSystem, makeInstance: nil)
    }

    /// Configures the singleton plugin to host instances of this actor.
    public func host<Act>(
        _ type: Act.Type = Act.self,
        name: String,
        settings: ActorSingletonSettings,
        makeInstance factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act where Act: ClusterSingletonProtocol
    {
        var settings = settings
        settings.name = name
        return try await self.proxy(type, settings: settings, system: self.actorSystem, makeInstance: factory)
    }

    internal func proxy<Act>(
        _ type: Act.Type,
        settings: ActorSingletonSettings,
        system: ClusterSystem,
        makeInstance factory: ((ClusterSystem) async throws -> Act)?
    ) async throws -> Act where Act: ClusterSingletonProtocol
    {
        let known = self.singletons["\(type)"]
        if let existingID = known?.proxyID {
            return try Act.resolve(id: existingID, using: system)
        }

        // Spawn the proxy for the singleton (one per singleton per node)
        let proxy = // try await _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singletonProxy-\(settings.name)")) {
            try await ActorSingletonProxy(
                settings: settings,
                system: system,
                singletonProps: .init(),
                factory
            )
        // }
        let interceptor = ActorSingletonRemoteCallInterceptor(system: system, proxy: proxy)
        let proxied = try system.interceptCalls(to: type, metadata: ActorMetadata(), interceptor: interceptor)

        return proxied
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorSingletonPlugin: _Plugin {
    static let pluginKey = _PluginKey<ActorSingletonPlugin>(plugin: "$clusterSingleton")

    public nonisolated var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ClusterSystem) async throws {
        self.actorSystem = system
    }

    public nonisolated func stop(_ system: ClusterSystem) {
        Task {
            await self.doStop()
        }
    }
    
    internal func doStop() {
        self.actorSystem = nil
        for (_, (_, proxy)) in self.singletons {
            proxy.stop()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton refs and actors

extension ClusterSystem {
    public var singleton: ActorSingletonPlugin {
        let key = ActorSingletonPlugin.pluginKey
        guard let singletonPlugin = self.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.settings.plugins)")
        }
        return singletonPlugin
    }
}
