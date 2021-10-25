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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol

public protocol AnyPlugin {
    /// Starts the plugin.
    // TODO: move to async function
    func start(_ system: ActorSystem) -> Result<Void, Error>

    /// Stops the plugin.
    // TODO: move to async function
    func stop(_ system: ActorSystem) -> Result<Void, Error>

}

/// A plugin provides specific features and capabilities (e.g., singleton) to an `ActorSystem`.
public protocol Plugin: AnyPlugin {
    typealias Key = PluginKey<Self>

    /// The plugin's unique identifier
    var key: Key { get }
}

internal struct BoxedPlugin: AnyPlugin {
    private let underlying: AnyPlugin

    let key: AnyPluginKey

    init<P: Plugin>(_ plugin: P) {
        self.underlying = plugin
        self.key = AnyPluginKey(plugin.key)
    }

    func unsafeUnwrapAs<P: Plugin>(_: P.Type) -> P {
        guard let unwrapped = self.underlying as? P else {
            fatalError("Type mismatch, expected: [\(String(reflecting: P.self))] got [\(self.underlying)]")
        }
        return unwrapped
    }

    func start(_ system: ActorSystem) -> Result<Void, Error> {
        self.underlying.start(system)
    }

    func stop(_ system: ActorSystem) -> Result<Void, Error> {
        self.underlying.stop(system)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin key

public struct PluginKey<P: Plugin>: CustomStringConvertible {
    public let plugin: String
    public let sub: String?

    internal var asAny: AnyPluginKey {
        AnyPluginKey(self)
    }

    public init(plugin: String) {
        self.init(plugin: plugin, sub: nil)
    }

    private init(plugin: String, sub: String?) {
        self.plugin = plugin
        self.sub = sub
    }

    public func makeSub(_ sub: String) -> PluginKey {
        precondition(self.sub == nil, "Cannot make a sub plugin key from \(self) (sub MUST be nil)")
        return .init(plugin: self.plugin, sub: sub)
    }

    public var description: String {
        if let sub = self.sub {
            return "PluginKey<\(P.self)>(\(self.plugin), sub: \(sub))"
        } else {
            return "PluginKey<\(P.self)>(\(self.plugin))"
        }
    }
}

internal struct AnyPluginKey: Hashable, CustomStringConvertible {
    let pluginTypeId: ObjectIdentifier
    let plugin: String
    let sub: String?

    init<P: Plugin>(_ key: PluginKey<P>) {
        self.pluginTypeId = ObjectIdentifier(P.self)
        self.plugin = key.plugin
        self.sub = key.sub
    }

    var description: String {
        if let sub = self.sub {
            return "AnyPluginKey(\(self.plugin), sub: \(sub))"
        } else {
            return "AnyPluginKey(\(self.plugin))"
        }
    }
}
