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
// MARK: VirtualNamespace refs and actors

extension ActorSystem {
    /// Entry point to interacting with the `VirtualNamespace`
    public var virtual: VirtualNamespaceControl {
        .init(self)
    }
}

public struct VirtualNamespaceExtension {
    private let system: ActorSystem
    private let namespacePlugin: VirtualNamespacePlugin

    internal init(_ system: ActorSystem) {
        let key = VirtualNamespacePlugin.pluginKey
        guard let plugin = system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(system.settings.plugins)")
        }
        self.system = system
        self.namespacePlugin = plugin
    }

    public func namespace<Message>(behavior: Behavior<Message>) -> VirtualNamespaceControl {
        self.namespacePlugin.activate()
        return .init(system: self.system, namespacePlugin: self.namespacePlugin)
    }
}

public struct VirtualNamespaceControl {
    private let system: ActorSystem
    private let namespacePlugin: VirtualNamespacePlugin

    public init(system: ActorSystem, namespacePlugin: VirtualNamespacePlugin) {
        self.system = system
        self.namespacePlugin = namespacePlugin
    }

    public func ref<Message: Codable>(
        _ uniqueName: String,
    ) throws -> ActorRef<Message> {
        try self.namespacePlugin.ref(uniqueName, of: type, system: self.system)
    }

    public func actor<Act: Actorable>(
        _ uniqueName: String,
        of type: Act.Type = Act.self
    ) throws -> Actor<Act> {
        try self.namespacePlugin.actor(uniqueName, of: type, system: self.system)
    }
}
