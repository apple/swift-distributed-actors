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

extension ActorMetadataKeys {
    public var clusterSingletonID: Key<String> { "$singleton-id" }
}

public protocol ClusterSingletonProtocol: DistributedActor where ActorSystem == ClusterSystem {
    /// Must be implemented using a `@ActorID.Metadata(\.clusterSingletonID)` annotated property.
    var singletonName: String { get }
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

    public func proxy<Act>(
        of type: Act.Type,
        system: ClusterSystem
    ) async throws -> Act
        where Act: ClusterSingletonProtocol
    {
        let settings = ActorSingletonSettings(name: "FIXME-NAME")
        return try await self.proxy(of: type, settings: settings, system: system, makeInstance: nil)
    }

    public func host<Act>(
        of type: Act.Type = Act.self,
        system: ClusterSystem,
        makeInstance factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: ClusterSingletonProtocol
    {
        let settings = ActorSingletonSettings(name: "FIXME-NAME")
        return try await self.proxy(of: type, settings: settings, system: system, makeInstance: factory)
    }

    public func proxy<Act>(
        of type: Act.Type,
        settings: ActorSingletonSettings,
        system: ClusterSystem,
        makeInstance factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        let known = self.singletons[settings.name]
        if let existingID = known?.proxyID {
            return try Act.resolve(id: existingID, using: system)
        }

        // Spawn the proxy for the singleton (one per singleton per node)
        let proxy = try await _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singletonProxy-\(settings.name)")) {
            try await ActorSingletonProxy(
                settings: settings,
                system: system,
                singletonProps: .init(),
                factory
            )
        }
        let interceptor = ActorSingletonRemoteCallInterceptor(system: system, proxy: proxy)
        let proxied = try system.interceptCalls(to: type, metadata: ActorMetadata(), interceptor: interceptor)

        return proxied
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorSingletonPlugin: _Plugin {
    static let pluginKey = _PluginKey<ActorSingletonPlugin>(plugin: "$actorSingleton")

    public nonisolated var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ClusterSystem) async throws {}

    public nonisolated func stop(_ system: ClusterSystem) {
        Task {
            for (_, (_, proxy)) in await self.singletons {
                proxy.stop()
            }
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
