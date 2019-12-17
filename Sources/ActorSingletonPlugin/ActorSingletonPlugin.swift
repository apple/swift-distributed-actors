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

extension ActorSystem {
    public var singleton: ActorSingletonLookup {
        .init(self)
    }
}

extension ActorSystemSettings {
    public static func += <P: Plugin>(settings: inout ActorSystemSettings, plugin: P) {
        settings.plugins.add(plugin)
    }
}

extension PluginsSettings {
    public static func += <P: Plugin>(plugins: inout PluginsSettings, plugin: P) {
        plugins.add(plugin)
    }
}

/// Allows for simplified lookups of actor references which are known to be managed by `ActorSingleton`.
public struct ActorSingletonLookup {
    private let system: ActorSystem

    internal init(_ system: ActorSystem) {
        self.system = system
    }

    /// Obtains a reference to a (proxy) singleton regardless of its current location.
    public func ref<Message>(name: String, of type: Message.Type) throws -> ActorRef<Message> {
        let key = ActorSingleton<Message>.pluginKey(name: name)
        guard let singleton = self.system.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.system.settings.plugins)")
        }
        return singleton.proxy // FIXME: Worried that we never synchronize access to proxy...
    }

    public func actor<Act: Actorable>(name: String, _ type: Act.Type) throws -> Actor<Act> {
        let ref = try self.ref(name: name, of: Act.Message.self)
        return Actor<Act>(ref: ref)
    }
}
