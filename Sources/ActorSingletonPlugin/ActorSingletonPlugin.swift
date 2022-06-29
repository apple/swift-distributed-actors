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
    private var singletons: [String: (proxied: ActorID, proxy: any AnyActorSingletonProxy)] = [:]

    public func proxy<Act>(
        of type: Act.Type,
        settings: ActorSingletonSettings,
        system: ClusterSystem,
        props: _Props = _Props(),
        _ factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        if let existingID = self.singletons[settings.name]?.proxied {
            return try Act.resolve(id: existingID, using: system)
        }

        // Spawn the proxy for the singleton (one per singleton per node)
        let proxy = try await _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singletonProxy-\(settings.name)")) {
            try await ActorSingletonProxy(
                settings: settings,
                system: system,
                singletonProps: props,
                factory
            )
        }

        // Assign the singleton actor a special id and set up the remote call interceptor
        var id = _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singleton-\(settings.name)")) {
            system.assignID(Act.self)
        }
        id.context.remoteCallInterceptor = ActorSingletonRemoteCallInterceptor(system: system, proxy: proxy)
        // Make id remote so everything is remote call
        id = id._asRemote

        // Save the actor id and proxy
        self.singletons[settings.name] = (id, proxy)

        let proxiedAct = try Act.resolve(id: id, using: system)
        return proxiedAct
    }
}

extension ActorSingletonPlugin {
    public func proxy<Act>(
        of type: Act.Type,
        name: String,
        system: ClusterSystem,
        props: _Props = _Props(),
        _ factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        let settings = ActorSingletonSettings(name: name)
        return try await self.proxy(of: type, settings: settings, system: system, props: props, factory)
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
    public var singleton: ActorSingletonControl {
        .init(self)
    }
}

/// Provides actor singleton controls such as obtaining a singleton and defining a singleton.
public struct ActorSingletonControl {
    private let system: ClusterSystem

    internal init(_ system: ClusterSystem) {
        self.system = system
    }

    private var singletonPlugin: ActorSingletonPlugin {
        let key = ActorSingletonPlugin.pluginKey
        guard let singletonPlugin = self.system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.system.settings.plugins)")
        }
        return singletonPlugin
    }

    /// Defines a singleton and indicates that it can be hosted on this node.
    public func proxy<Act>(
        _ type: Act.Type,
        name: String,
        props: _Props = _Props(),
        _ factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        try await self.singletonPlugin.proxy(of: type, name: name, system: self.system, props: props, factory)
    }

    /// Defines a singleton and indicates that it can be hosted on this node.
    public func proxy<Act>(
        _ type: Act.Type,
        settings: ActorSingletonSettings,
        props: _Props = _Props(),
        _ factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        try await self.singletonPlugin.proxy(of: type, settings: settings, system: self.system, props: props, factory)
    }

    public func proxy<Act>(
        _ type: Act.Type,
        name: String
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        try await self.singletonPlugin.proxy(of: type, name: name, system: self.system)
    }
}
