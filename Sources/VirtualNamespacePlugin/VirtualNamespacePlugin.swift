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
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual namespace plugin

public final class VirtualNamespacePlugin {
    let settings: VirtualNamespaceSettings

    private let lock: Lock

    // TODO can we make this a bit more nice / type safe rather than the cast inside the any wrapper?
    private var namespaces: [NamespaceID: AnyVirtualNamespaceActorRef]

    public init(settings: VirtualNamespaceSettings = .default) {
        self.settings = settings
        self.lock = Lock()
        self.namespaces = [:]
    }

    func ref<Message: Codable>(
        _ uniqueName: String,
        of type: Message.Type,
        system: ActorSystem,
        props: Props? = nil,
        _ behavior: Behavior<Message>
    ) throws -> ActorRef<Message> {
        guard let namespace: ActorRef<VirtualNamespaceActor<Message>.Message> = (try self.lock.withLock {
            let namespaceID = NamespaceID(messageType: type)

            if let namespace = self.namespaces[namespaceID] {
                return namespace.asNamespaceRef(of: Message.self)
            } else {
                // FIXME: proper paths
                let namespaceBehavior = VirtualNamespaceActor(managing: behavior).behavior
                let namespaceName = ActorNaming(_unchecked: .unique("$virtual-manager-\(namespaceID.id.hashValue)")) // FIXME the name should be better
                let namespace = try system._spawnSystemActor(namespaceName, namespaceBehavior)
                self.namespaces[namespaceID] = .init(ref: namespace, deadLetters: system.deadLetters)
                return namespace
            }
        }) else {
            return system.personalDeadLetters(recipient: .init(local: system.cluster.uniqueNode, path: ._virtual, incarnation: .wellKnown))
        }

        let virtualPersonality = try VirtualActorPersonality<Message>(
            system: system,
            namespace: namespace,
            address: ActorAddress.virtualAddress(local: system.cluster.uniqueNode, identity: uniqueName)
        )
        let virtualRef = ActorRef(.delegate(virtualPersonality))
        system.log.info("emitted: \(virtualRef)")

        return virtualRef
    }

    func actor<Act: Actorable>(
        _ uniqueName: String,
        of type: Act.Type,
        system: ActorSystem,
        props: Props? = nil,
        _ makeInstance: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> {
        let behavior =
            Behavior<Act.Message>.setup { context in
                Act.makeBehavior(instance: makeInstance(.init(underlying: context)))
            }

        let ref = try self.ref(uniqueName, of: type.Message.self, system: system, props: props, behavior)
        return Actor(ref: ref)
    }
}

struct NamespaceID: Hashable {
    let id: ObjectIdentifier

    init<Message: Codable>(messageType: Message.Type) {
        self.id = ObjectIdentifier(messageType)
    }

    init<Act: Actorable>(actorType: Act.Type) {
        self.id = ObjectIdentifier(actorType)
    }
}

extension ActorAddress {
    static func virtualAddress(local: UniqueNode, identity: String) throws -> ActorAddress {
        .init(local: local, path: try ActorPath._virtual.appending(identity), incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static let _virtual: ActorPath = try! ActorPath._root.appending("$virtual")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension VirtualNamespacePlugin: Plugin {
    static let pluginKey = PluginKey<VirtualNamespacePlugin>(plugin: "virtualNamespace")

    public var key: Key {
        Self.pluginKey
    }

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        system.log.info("Initialized plugin: \(Self.self)")
        return .success(())
    }

    // TODO: Future
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        system.log.info("Stopping plugin: \(Self.self)")
        self.lock.withLock {
            for (_, namespace) in self.namespaces {
                namespace.stop()
            }
        }
        return .success(())
    }
}

extension ActorNaming {
    static var virtual: ActorNaming = "$virtual"
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace refs and actors

extension ActorSystem {
    /// Entry point to interacting with the `VirtualNamespace`
    public var virtual: VirtualNamespaceControl {
        .init(self)
    }
}

public struct VirtualNamespaceControl {
    private let system: ActorSystem

    internal init(_ system: ActorSystem) {
        self.system = system
    }

    private var namespacePlugin: VirtualNamespacePlugin {
        let key = VirtualNamespacePlugin.pluginKey
        guard let singletonPlugin = self.system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.system.settings.plugins)")
        }
        return singletonPlugin
    }

    public func ref<Message: Codable>(
        _ uniqueName: String,
        of type: Message.Type = Message.self,
        props: Props? = nil,
        _ behavior: Behavior<Message>
    ) throws -> ActorRef<Message> {
        try self.namespacePlugin.ref(uniqueName, of: type, system: self.system, props: props, behavior)
    }

    public func actor<Act: Actorable>(
        _ uniqueName: String,
        of type: Act.Type = Act.self,
        props: Props? = nil,
        _ makeInstance: @escaping (Actor<Act>.Context) -> Act
    ) throws -> Actor<Act> {
        try self.namespacePlugin.actor(uniqueName, of: type, system: self.system, props: props, makeInstance)
    }
}
