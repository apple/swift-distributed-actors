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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton plugin

/// `ClusterSingletonPlugin` ensures that there is no more than one instance of a distributed actor running in the cluster.
///
/// A singleton may run on any node in the cluster. Use `ClusterSingletonSettings.allocationStrategy` to control
/// its allocation. On candidate nodes where the singleton might run, use `ClusterSystem.singleton.add(type:name:props:factory:)`
/// to define the cluster singleton. Otherwise, call `ClusterSystem.singleton.get(type:name:)` to obtain the singleton. The returned
/// `DistributedActor` is in reality a proxy that handles situations where the singleton might get relocated to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///            the singleton allocation.
/// - SeeAlso: The `ClusterSingleton` mechanism is conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
///            and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public actor ClusterSingletonPlugin {
    private var singletons: [String: (id: ActorID, singleton: any ClusterSingletonProtocol)] = [:]

    public func add<Act>(
        _ type: Act.Type,
        settings: ClusterSingletonSettings,
        system: ClusterSystem,
        props: _Props? = nil,
        _ factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        if let existingID = self.singletons[settings.name]?.id {
            return try Act.resolve(id: existingID, using: system)
        }

        // Spawn the proxy for the singleton (one per singleton per node)
        let singleton = try await _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singleton-\(settings.name)")) {
            try await ClusterSingleton(
                settings: settings,
                system: system,
                singletonProps: props,
                factory
            )
        }

        // Assign the singleton actor a special id and set up the remote call interceptor
        var id = _Props.$forSpawn.withValue(_Props._wellKnownActor(name: settings.name)) {
            system.assignID(Act.self)
        }
        id.context.remoteCallInterceptor = ClusterSingletonRemoteCallInterceptor(system: system, singleton: singleton)
        // Make id remote so everything is remote call
        id = id._asRemote

        // Save the actor id and proxy
        self.singletons[settings.name] = (id, singleton)

        let act = try Act.resolve(id: id, using: system)
        return act
    }
}

extension ClusterSingletonPlugin {
    public func add<Act>(
        _ type: Act.Type,
        name: String,
        system: ClusterSystem,
        props: _Props? = nil,
        _ factory: ((ClusterSystem) async throws -> Act)? = nil
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        let settings = ClusterSingletonSettings(name: name)
        return try await self.add(type, settings: settings, system: system, props: props, factory)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ClusterSingletonPlugin: _Plugin {
    static let pluginKey = _PluginKey<ClusterSingletonPlugin>(plugin: "$clusterSingleton")

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
// MARK: Cluster singleton and system integration

extension ClusterSystem {
    public var singleton: ClusterSingletonControl {
        .init(self)
    }
}

/// Provides cluster singleton controls such as defining and obtaining a singleton.
public struct ClusterSingletonControl {
    private let system: ClusterSystem

    internal init(_ system: ClusterSystem) {
        self.system = system
    }

    private var singletonPlugin: ClusterSingletonPlugin {
        let key = ClusterSingletonPlugin.pluginKey
        guard let singletonPlugin = self.system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.system.settings.plugins)")
        }
        return singletonPlugin
    }

    /// Defines a singleton and indicates that it can be hosted on this node.
    public func add<Act>(
        _ type: Act.Type,
        name: String,
        props: _Props = _Props(),
        _ factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        try await self.singletonPlugin.add(type, name: name, system: self.system, props: props, factory)
    }

    /// Defines a singleton and indicates that it can be hosted on this node.
    public func add<Act>(
        _ type: Act.Type,
        settings: ClusterSingletonSettings,
        props: _Props = _Props(),
        _ factory: @escaping (ClusterSystem) async throws -> Act
    ) async throws -> Act
        where Act: DistributedActor,
        Act.ActorSystem == ClusterSystem
    {
        try await self.singletonPlugin.add(type, settings: settings, system: self.system, props: props, factory)
    }

    /// Obtains a singleton.
    public func get<Act>(_ type: Act.Type, name: String) async throws -> Act where Act: DistributedActor, Act.ActorSystem == ClusterSystem {
        try await self.singletonPlugin.add(type, name: name, system: self.system)
    }
}
