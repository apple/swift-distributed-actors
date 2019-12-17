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
        .init(system: self)
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

    internal init(system: ActorSystem) {
        self.system = system
    }

    /// Obtain a reference to a (proxy) singleton regardless of its current location.
    public func ref<Message>(name: String, of type: Message.Type) throws -> ActorRef<Message> {

        // TODO: if this was implemented by a receptionist lookup, or similar, then we would also be able to handle
        // actors spawned AFTER the setup of the system; Which we may want to support for some reason;
        // Lack of Future here is quite annoying since we'd have to leak the NIO one and awaiting on it is a pain...

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

public enum ActorSingletonError: Error {
    /// A singleton with `name` already exists.
    case nameAlreadyExists(String)
    /// There is no registered singleton identified by `name`.
    case unknown(name: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Settings for `ActorSingletonPlugin`

public struct ActorSingletonPluginSettings {
    public static var `default`: ActorSingletonPluginSettings {
        .init()
    }

    public init() {}

}

internal enum AllocationStrategyEvent {
    case clusterEvent(ClusterEvent)
}
