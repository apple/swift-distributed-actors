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
    // TODO: return a Future<> once we have such abstraction, such that plugin can ensure "to be ready" within some time
    func start(_ system: ActorSystem) -> Result<Void, Error>

    /// Stops the plugin.
    // TODO: return a Future<> once we have such abstraction, such that plugin can ensure "to be ready" within some time
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

    internal let key: AnyPluginKey

    internal init<P: Plugin>(_ plugin: P) {
        self.underlying = plugin
        self.key = AnyPluginKey(plugin.key)
    }

    internal func unsafeUnwrapAs<P: Plugin>(_: P.Type) -> P {
        guard let unwrapped = self.underlying as? P else {
            fatalError("Type mismatch, expected: [\(String(reflecting: P.self))] got [\(self.underlying)]")
        }
        return unwrapped
    }

    internal func start(_ system: ActorSystem) -> Result<Void, Error> {
        return self.underlying.start(system)
    }

    internal func stop(_ system: ActorSystem) -> Result<Void, Error> {
        return self.underlying.stop(system)
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
    internal let pluginTypeId: ObjectIdentifier
    internal let plugin: String
    internal let sub: String?

    internal init<P: Plugin>(_ key: PluginKey<P>) {
        self.pluginTypeId = ObjectIdentifier(P.self)
        self.plugin = key.plugin
        self.sub = key.sub
    }

    public var description: String {
        if let sub = self.sub {
            return "AnyPluginKey(\(self.plugin), sub: \(sub))"
        } else {
            return "AnyPluginKey(\(self.plugin))"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugins settings

/// Settings for `ActorSystem` plugins.
public struct PluginsSettings {
    public static var `default`: PluginsSettings {
        .init()
    }

    internal var plugins: [BoxedPlugin] = []

    public init() {}

    /// Adds a `Plugin`.
    ///
    /// - Note: A plugin that depends on others should be added *after* its dependencies.
    /// - Faults, when plugin of the exact same `PluginKey` is already included in the settings
    public mutating func add<P: Plugin>(_ plugin: P) {
        precondition(
            !self.plugins.contains(where: { $0.key == plugin.key.asAny }),
            "Attempted to add plugin \(plugin.key) but key already used! Plugin [\(plugin)], installed plugins: \(self.plugins)."
        )

        return self.plugins.append(BoxedPlugin(plugin))
    }

    /// Returns `Plugin` identified by `key`.
    public subscript<P: Plugin>(_ key: PluginKey<P>) -> P? {
        self.plugins.first { $0.key == key.asAny }?.unsafeUnwrapAs(P.self)
    }

    /// Starts all plugins in the same order as they were added.
    internal func startAll(_ system: ActorSystem) {
        for plugin in self.plugins {
            if case .failure(let error) = plugin.start(system) {
                fatalError("Failed to start plugin \(plugin.key)! Error: \(error)")
            }
        }
    }

    /// Stops all plugins in the *reversed* order as they were added.
    internal func stopAll(_ system: ActorSystem) {
        // Shut down in reversed order so plugins with the fewest dependencies are stopped first!
        for plugin in self.plugins.reversed() {
            if case .failure(let error) = plugin.stop(system) {
                fatalError("Failed to stop plugin \(plugin.key)! Error: \(error)")
            }
        }
    }
}
