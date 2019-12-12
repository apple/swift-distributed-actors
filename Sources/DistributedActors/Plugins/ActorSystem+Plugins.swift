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
    func start(_ system: ActorSystem) -> Result<Void, Error>

    /// Stops the plugin.
    func stop(_ system: ActorSystem) -> Result<Void, Error>
}

/// A plugin provides specific features and capabilities (e.g., singleton) to an `ActorSystem`.
public protocol Plugin: AnyPlugin {
    typealias Key = PluginKey<Self>

    /// The plugin's unique identifier
    static var key: Key { get }
}

internal struct BoxedPlugin: AnyPlugin {
    private let underlying: AnyPlugin

    internal let key: AnyPluginKey

    internal init<P: Plugin>(_ plugin: P) {
        self.underlying = plugin
        self.key = AnyPluginKey(P.key)
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

public struct PluginKey<P: Plugin>: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, CustomStringConvertible {
    public let name: String

    internal var asAny: AnyPluginKey {
        AnyPluginKey(self)
    }

    public init(stringLiteral value: String) {
        self.name = value
    }

    public var description: String {
        "PluginKey(\(self.name))"
    }
}

internal struct AnyPluginKey: Equatable, CustomStringConvertible {
    internal let pluginTypeId: ObjectIdentifier
    internal let name: String

    internal init<P: Plugin>(_ key: PluginKey<P>) {
        self.pluginTypeId = ObjectIdentifier(P.self)
        self.name = key.name
    }

    public var description: String {
        "AnyPluginKey(\(self.name))"
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
    public mutating func add<P: Plugin>(_ plugin: P) {
        return self.plugins.append(BoxedPlugin(plugin))
    }

    /// Returns `Plugin` identified by `key`.
    public subscript<P: Plugin>(_: PluginKey<P>) -> P? {
        self.plugins.first { $0.key == P.key.asAny }?.unsafeUnwrapAs(P.self)
    }

    /// Starts all plugins in the same order as they were added.
    internal func startAll(_ system: ActorSystem) {
        for plugin in self.plugins {
            if case .failure(let error) = plugin.start(system) {
                fatalError("Failed to start plugin \(plugin.key.name)! Error: \(error)")
            }
        }
    }

    /// Stops all plugins in the *reversed* order as they were added.
    internal func stopAll(_ system: ActorSystem) {
        // Shut down in reversed order so plugins with the fewest dependencies are stopped first!
        for plugin in self.plugins.reversed() {
            if case .failure(let error) = plugin.stop(system) {
                fatalError("Failed to stop plugin \(plugin.key.name)! Error: \(error)")
            }
        }
    }
}

extension PluginsSettings {
    public static func += <P: Plugin>(lhs: inout PluginsSettings, rhs: P) {
        lhs.add(rhs)
    }
}
