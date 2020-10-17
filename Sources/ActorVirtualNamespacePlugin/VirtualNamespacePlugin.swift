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
// MARK: Virtual namespace plugin

public final class VirtualNamespacePlugin {
    public init() {}

    // FIXME: document that may crash, it may right?
    func ref<Message: ActorMessage>(of type: Message.Type, settings: VirtualNamespaceSettings, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        try self.singletonsLock.withLock {
            if let existing = self.singletons[settings.name] {
                guard let proxy = existing.unsafeUnwrapAs(Message.self).proxy else {
                    fatalError("VirtualNamespace [\(settings.name)] not yet initialized")
                }
                return proxy
            }

            let singleton = ActorVirtualNamespace<Message>(settings: settings, props: props, behavior)
            try singleton.spawnAll(system)
            self.singletons[settings.name] = BoxedActorVirtualNamespace(singleton)

            guard let proxy = singleton.proxy else {
                fatalError("VirtualNamespace[\(settings.name)] not yet initialized")
            }

            return proxy
        }
    }

    func actor<Act: Actorable>(of type: Act.Type, settings: ActorVirtualNamespaceSettings, system: ActorSystem, props: Props? = nil, _ makeInstance: ((Actor<Act>.Context) -> Act)? = nil) throws -> Actor<Act> {
        let behavior = makeInstance.map { maker in
            Behavior<Act.Message>.setup { context in
                Act.makeBehavior(instance: maker(.init(underlying: context)))
            }
        }
        let ref = try self.ref(of: Act.Message.self, settings: settings, system: system, behavior)
        return Actor<Act>(ref: ref)
    }
}

extension ActorVirtualNamespacePlugin {
    func ref<Message>(of type: Message.Type, name: String, system: ActorSystem, props: Props? = nil, _ behavior: Behavior<Message>? = nil) throws -> ActorRef<Message> {
        let settings = ActorVirtualNamespaceSettings(name: name)
        return try self.ref(of: type, settings: settings, system: system, props: props, behavior)
    }

    func actor<Act: Actorable>(of type: Act.Type, name: String, system: ActorSystem, props: Props? = nil, _ makeInstance: ((Actor<Act>.Context) -> Act)? = nil) throws -> Actor<Act> {
        let settings = ActorVirtualNamespaceSettings(name: name)
        return try self.actor(of: type, settings: settings, system: system, props: props, makeInstance)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorVirtualNamespacePlugin: Plugin {
    static let pluginKey = PluginKey<ActorVirtualNamespacePlugin>(plugin: "$actorVirtualNamespace")

    public var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        .success(())
    }

    // TODO: Future
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        self.singletonsLock.withLock {
            for (_, singleton) in self.singletons {
                singleton.stop(system)
            }
        }
        return .success(())
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace refs and actors

extension ActorSystem {
    public var singleton: ActorVirtualNamespaceControl {
        .init(self)
    }
}

/// Provides actor singleton controls such as obtaining a singleton ref and defining the singleton.
public struct ActorVirtualNamespaceControl {
    private let system: ActorSystem

    internal init(_ system: ActorSystem) {
        self.system = system
    }

    private var singletonPlugin: ActorVirtualNamespacePlugin {
        let key = ActorVirtualNamespacePlugin.pluginKey
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
    public func host<Message>(_ type: Message.Type, settings: ActorVirtualNamespaceSettings, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.singletonPlugin.ref(of: type, settings: settings, system: self.system, props: props, behavior)
    }

    /// Defines a singleton `Actorable` and indicates that it can be hosted on this node.
    public func host<Act: Actorable>(_ type: Act.Type, name: String, props: Props = Props(), _ makeInstance: @escaping (Actor<Act>.Context) -> Act) throws -> Actor<Act> {
        try self.singletonPlugin.actor(of: type, name: name, system: self.system, props: props, makeInstance)
    }

    /// Defines a singleton `Actorable` and indicates that it can be hosted on this node.
    public func host<Act: Actorable>(_ type: Act.Type, settings: ActorVirtualNamespaceSettings, props: Props = Props(), _ makeInstance: @escaping (Actor<Act>.Context) -> Act) throws -> Actor<Act> {
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
