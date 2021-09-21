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
import DistributedActorsConcurrencyHelpers

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
    private let singletonsLock = Lock()

    public init() {}

    // FIXME: document that may crash, it may right?
    func ref<Message: ActorMessage>(of type: Message.Type, settings: ActorSingletonSettings, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        try self.singletonsLock.withLock {
            if let existing = self.singletons[settings.name] {
                guard let proxy = existing.unsafeUnwrapAs(Message.self).proxy else {
                    fatalError("Singleton [\(settings.name)] not yet initialized")
                }
                return proxy
            }

            let singleton = ActorSingleton<Message>(settings: settings, props: props, behavior)
            try singleton.spawnAll(system)
            self.singletons[settings.name] = BoxedActorSingleton(singleton)

            guard let proxy = singleton.proxy else {
                fatalError("Singleton[\(settings.name)] not yet initialized")
            }

            return proxy
        }
    }

    func actor<Act: Actorable>(of type: Act.Type, settings: ActorSingletonSettings, system: ActorSystem, props: Props? = nil, _ makeInstance: ((Actor<Act>.Context) -> Act)? = nil) throws -> Actor<Act> {
        let behavior = makeInstance.map { maker in
            Behavior<Act.Message>.setup { context in
                Act.makeBehavior(instance: maker(.init(underlying: context)))
            }
        }
        let ref = try self.ref(of: Act.Message.self, settings: settings, system: system, behavior)
        return Actor<Act>(ref: ref)
    }
}

extension ActorSingletonPlugin {
    func ref<Message>(of type: Message.Type, name: String, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        let settings = ActorSingletonSettings(name: name)
        return try self.ref(of: type, settings: settings, system: system, props: props, behavior)
    }

    func actor<Act: Actorable>(of type: Act.Type, name: String, system: ActorSystem, props: Props? = nil, _ makeInstance: ((Actor<Act>.Context) -> Act)? = nil) throws -> Actor<Act> {
        let settings = ActorSingletonSettings(name: name)
        return try self.actor(of: type, settings: settings, system: system, props: props, makeInstance)
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

    // TODO: Future; TODO2: no need for this at all now since we have async await
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        self.singletonsLock.withLock {
            for (_, singleton) in self.singletons {
                singleton.stop(system)
            }
        }
        return .success(())
    }

//    public func stop(_ transport: ActorClusterTransport) async throws {
//        self.singletonsLock.withLock {
//            for (_, singleton) in self.singletons {
//                try await singleton.stop(transport)
//            }
//        }
//    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton refs and actors

extension ActorSystem {
    public var singleton: ActorSingletonControl {
        .init(self)
    }
}

/// Provides actor singleton controls such as obtaining a singleton ref and defining the singleton.
public struct ActorSingletonControl {
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

    /// Defines a singleton `behavior` and indicates that it can be hosted on this node.
    public func host<Message>(_ type: Message.Type, name: String, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, name: name, system: self.system, props: props, behavior)
    }

    /// Defines a singleton `behavior` and indicates that it can be hosted on this node.
    public func host<Message>(_ type: Message.Type, settings: ActorSingletonSettings, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, settings: settings, system: self.system, props: props, behavior)
    }

    /// Defines a singleton `Actorable` and indicates that it can be hosted on this node.
    public func host<Act: Actorable>(_ type: Act.Type, name: String, props: Props = Props(), _ makeInstance: @escaping (Actor<Act>.Context) -> Act) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, name: name, system: self.system, props: props, makeInstance)
    }

    /// Defines a singleton `Actorable` and indicates that it can be hosted on this node.
    public func host<Act: Actorable>(_ type: Act.Type, settings: ActorSingletonSettings, props: Props = Props(), _ makeInstance: @escaping (Actor<Act>.Context) -> Act) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, settings: settings, system: self.system, props: props, makeInstance)
    }

    /// Obtains a ref to the specified actor singleton.
    public func ref<Message>(of type: Message.Type, name: String) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, name: name, system: self.system)
    }

    /// Obtains the specified singleton actor.
    public func actor<Act: Actorable>(of type: Act.Type, name: String) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, name: name, system: self.system)
    }
}
