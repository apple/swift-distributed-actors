//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton plugin

/// The actor singleton plugin ensures that there is no more than one instance of an actor that is defined to be
/// singleton running in the cluster.
///
/// An actor singleton may run on any node in the cluster. Use `ActorSingletonSettings.allocationStrategy` to control
/// its allocation. On candidate nodes where the singleton might run, use `ActorSystem.singleton.ref(type:name:props:behavior)`
/// to define actor behavior. Otherwise, call `ActorSystem.singleton.ref(type:name:)` to obtain a ref. The returned
/// `ActorRef` is in reality a proxy which handle situations where the singleton is shifted to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///            the singleton allocation.
/// - SeeAlso: The `ActorSingleton` mechanism is conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
///            and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public final class ActorSingletonPlugin {
    private var singletons: [String: BoxedActorSingleton] = [:]

    public init() {}

    func ref<Message>(of type: Message.Type, settings: ActorSingletonSettings, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        if let existing = self.singletons[settings.name] {
            guard let proxy = existing.unsafeUnwrapAs(Message.self).proxy else {
                fatalError("Singleton[\(settings.name)] not yet initialized")
            }
            return proxy
        }

        let singleton = ActorSingleton<Message>(settings: settings, props: props, behavior)
        try singleton.spawnAll(system)
        self.singletons[settings.name] = BoxedActorSingleton(singleton)

        guard let proxy = singleton.proxy else {
            fatalError("Singleton[\(settings.name)] not yet initialized")
        }

        return proxy // FIXME: Worried that we never synchronize access to proxy...
    }

    func actor<Act: Actorable>(of type: Act.Type, settings: ActorSingletonSettings, system: ActorSystem, _ instance: Act? = nil) throws -> Actor<Act> {
        let behavior = instance.map { Act.makeBehavior(instance: $0) }
        let ref = try self.ref(of: Act.Message.self, settings: settings, system: system, behavior)
        return Actor<Act>(ref: ref)
    }
}

extension ActorSingletonPlugin {
    func ref<Message>(of type: Message.Type, name: String, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        let settings = ActorSingletonSettings(name: name)
        return try self.ref(of: type, settings: settings, system: system, props: props, behavior)
    }

    func actor<Act: Actorable>(of type: Act.Type, name: String, system: ActorSystem, _ instance: Act? = nil) throws -> Actor<Act> {
        let settings = ActorSingletonSettings(name: name)
        return try self.actor(of: type, settings: settings, system: system, instance)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorSingletonPlugin: Plugin {
    static let pluginKey = PluginKey<ActorSingletonPlugin>(plugin: "$actorSingleton")

    public var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        .success(())
    }

    // TODO: Future
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        for (_, singleton) in self.singletons {
            singleton.stop(system)
        }
        return .success(())
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton refs and actors

extension ActorSystem {
    public var singleton: ActorSingletonLookup {
        .init(self)
    }
}

/// Allows for simplified lookups of actor singleton refs.
public struct ActorSingletonLookup {
    private let system: ActorSystem

    internal init(_ system: ActorSystem) {
        self.system = system
    }

    private var singletonPlugin: ActorSingletonPlugin {
        let key = ActorSingletonPlugin.pluginKey
        guard let singletonPlugin = self.system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.system.settings.plugins)")
        }
        return singletonPlugin
    }

    /// Obtains a reference to an actor (proxy) singleton regardless of its current location.
    public func ref<Message>(of type: Message.Type, name: String, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, name: name, system: self.system, props: props, behavior)
    }

    public func ref<Message>(of type: Message.Type, settings: ActorSingletonSettings, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, settings: settings, system: self.system, props: props, behavior)
    }

    public func actor<Act: Actorable>(of type: Act.Type, name: String, _ instance: Act? = nil) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, name: name, system: self.system, instance)
    }

    public func actor<Act: Actorable>(of type: Act.Type, settings: ActorSingletonSettings, _ instance: Act? = nil) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, settings: settings, system: self.system, instance)
    }
}
