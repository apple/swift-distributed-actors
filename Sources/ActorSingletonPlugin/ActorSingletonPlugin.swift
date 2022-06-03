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

import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton plugin

/// The actor singleton plugin ensures that there is no more than one instance of an actor that is defined to be
/// singleton running in the cluster.
///
/// An actor singleton may run on any node in the cluster. Use `ActorSingletonSettings.allocationStrategy` to control
/// its allocation. On candidate nodes where the singleton might run, use `ClusterSystem.singleton.ref(type:name:props:behavior)`
/// to define actor behavior. Otherwise, call `ClusterSystem.singleton.ref(type:name:)` to obtain a ref. The returned
/// `_ActorRef` is in reality a proxy which handle situations where the singleton is shifted to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///            the singleton allocation.
/// - SeeAlso: The `ActorSingleton` mechanism is conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
///            and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public final class ActorSingletonPlugin {
    private var singletons: [String: BoxedActorSingleton] = [:]
    private let singletonsLock = Lock()

    public init() {}

    // FIXME: document that may crash, it may right?
    func ref<Message: ActorMessage>(of type: Message.Type, settings: ActorSingletonSettings, system: ClusterSystem, props: _Props? = nil, _ behavior: _Behavior<Message>? = nil) throws -> _ActorRef<Message> {
        try self.singletonsLock.withLock {
            if let existing = self.singletons[settings.name] {
                guard let proxy = existing.unsafeUnwrapAs(Message.self).proxy else {
                    fatalError("Singleton [\(settings.name)] not yet initialized")
                }
                return proxy
            }

            let singleton = ActorSingleton<Message>(settings: settings, props: props, behavior)
            try singleton.startAll(system)
            self.singletons[settings.name] = BoxedActorSingleton(singleton)

            guard let proxy = singleton.proxy else {
                fatalError("Singleton[\(settings.name)] not yet initialized")
            }

            return proxy
        }
    }
}

extension ActorSingletonPlugin {
    @available(*, deprecated, message: "Will be removed and replaced by API based on DistributedActor. Issue #824")
    func ref<Message>(of type: Message.Type, name: String, system: ClusterSystem, props: _Props? = nil, _ behavior: _Behavior<Message>? = nil) throws -> _ActorRef<Message> {
        let settings = ActorSingletonSettings(name: name)
        return try self.ref(of: type, settings: settings, system: system, props: props, behavior)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorSingletonPlugin: _Plugin {
    static let pluginKey = _PluginKey<ActorSingletonPlugin>(plugin: "$actorSingleton")

    public var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ClusterSystem) async throws {}

    public func stop(_ system: ClusterSystem) async throws {
        self.singletonsLock.withLock {
            for (_, singleton) in self.singletons {
                singleton.stop(system)
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

/// Provides actor singleton controls such as obtaining a singleton ref and defining the singleton.
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

    /// Defines a singleton `behavior` and indicates that it can be hosted on this node.
    public func host<Message>(_ type: Message.Type, name: String, props: _Props = _Props(), _ behavior: _Behavior<Message>) throws -> _ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, name: name, system: self.system, props: props, behavior)
    }

    /// Defines a singleton `behavior` and indicates that it can be hosted on this node.
    public func host<Message>(_ type: Message.Type, settings: ActorSingletonSettings, props: _Props = _Props(), _ behavior: _Behavior<Message>) throws -> _ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, settings: settings, system: self.system, props: props, behavior)
    }

    /// Obtains a ref to the specified actor singleton.
    public func ref<Message>(of type: Message.Type, name: String) throws -> _ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, name: name, system: self.system)
    }
}
