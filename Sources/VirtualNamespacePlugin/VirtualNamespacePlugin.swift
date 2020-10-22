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

    let managedBehaviors: [NamespaceID: _AnyBehavior]

//    // TODO: can we make this a bit more nice / type safe rather than the cast inside the any wrapper?
//    private var namespaces: [NamespaceID: AnyVirtualNamespaceActorRef]

    var pluginRef: ActorRef<VirtualNamespacePluginActor.Message>!

    public init(
        settings: VirtualNamespaceSettings = .default,
        behavior: _AnyBehavior, // TODO: accept many behaviors?
        props: Props? = nil
    ) {
        self.settings = settings
        self.lock = Lock()
        // self.namespaces = [:]
        self.managedBehaviors = [
            NamespaceID(messageType: behavior.messageType): behavior,
        ]
    }

    ///
    ///
    /// - Parameters:
    ///   - uniqueName:
    ///   - type:
    ///   - system:
    ///   - props:
    ///   - namespaceName: if nil, the namespace name will be derived from the `type`
    ///   - behavior:
    /// - Returns:
    /// - Throws:
    func ref<Message: Codable>(
        _ uniqueName: String,
        of type: Message.Type,
        system: ActorSystem
    ) throws -> ActorRef<Message> {
        let pluginRef = self.lock.withLock {
            self.pluginRef!
        }

        let virtualPersonality = try VirtualActorPersonality<Message>(
            system: system,
            plugin: pluginRef,
            address: ActorAddress.virtualAddress(local: system.cluster.uniqueNode, identity: uniqueName)
        )
        let virtualRef = ActorRef(.delegate(virtualPersonality))
        system.log.info("emitted: \(virtualRef)")

        return virtualRef
    }

    func actor<Act: Actorable>(
        _ uniqueName: String,
        of type: Act.Type,
        system: ActorSystem
    ) throws -> Actor<Act> {
        try Actor(ref: self.ref(uniqueName, of: type.Message.self, system: system))
    }
}

struct NamespaceID: Codable, Hashable {
    let typeName: String
    let namespaceName: String

    init(messageType: Any.Type) {
        // self.id = ObjectIdentifier(messageType)
        self.typeName = _typeName(messageType)
        self.namespaceName = String(reflecting: messageType)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.typeName)
    }

    static func == (lhs: NamespaceID, rhs: NamespaceID) -> Bool {
        lhs.typeName == rhs.typeName
    }
}

extension ActorAddress {
    // /system/$virtual
    static func virtualPlugin(remote node: UniqueNode) -> ActorAddress {
        .init(remote: node, path: ActorPath._virtual, incarnation: .wellKnown)
    }

    static func virtualAddress(local: UniqueNode, identity: String) throws -> ActorAddress {
        .init(local: local, path: try ActorPath._virtual.appending(identity), incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static let _virtual: ActorPath = try! ActorPath._system.appending("$virtual")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension VirtualNamespacePlugin: Plugin {
    static let pluginKey = PluginKey<VirtualNamespacePlugin>(plugin: "$virtualNamespace")

    public var key: Key {
        Self.pluginKey
    }

    public func configure(settings: inout ActorSystemSettings) {
        settings.serialization.register(CASPaxos<UniqueNode>.Message.self)
    }

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        system.log.info("Initialized plugin: \(Self.self)")
        do {
            self.pluginRef = try system._spawnSystemActor(
                ActorNaming(_unchecked: .unique("$virtual")),
                VirtualNamespacePluginActor(
                    settings: self.settings,
                    managedBehaviors: self.managedBehaviors
                ).behavior,
                props: ._wellKnown
            )
        } catch {
            return .failure(error)
        }

        return .success(())
    }

    // TODO: Future
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        system.log.info("Stopping plugin: \(Self.self)")
        self.lock.withLock {
            self.pluginRef.tell(.stop)
        }
        return .success(())
    }
}
