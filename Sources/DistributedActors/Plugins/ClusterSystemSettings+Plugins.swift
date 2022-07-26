//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Settings for `ClusterSystem` plugins.
///
/// Use to enable additional plugins that are started and stopped along with the cluster system.
public struct PluginsSettings {
    public static var `default`: PluginsSettings {
        .init()
    }

    internal var plugins: [BoxedPlugin] = []

    public init() {}

    /// Adds a `_Plugin`.
    ///
    /// - Note: A plugin that depends on others should be added *after* its dependencies.
    /// - Faults, when plugin of the exact same `PluginKey` is already included in the settings.
    @available(*, deprecated, message: "use settings.install(plugin:) instead")
    public mutating func add<P: _Plugin>(_ plugin: P) {
        self.install(plugin: plugin)
    }

    /// Returns `Plugin` identified by `key`.
    public subscript<P: _Plugin>(_ key: _PluginKey<P>) -> P? {
        self.plugins.first { $0.key == key.asAny }?.unsafeUnwrapAs(P.self)
    }

    /// Starts all plugins in the same order as they were added.
    internal func startAll(_ system: ClusterSystem) async {
        for plugin in self.plugins {
            do {
                system.log.info("Starting cluster system plugin: \(plugin.key)")
                try await plugin.start(system)
            } catch {
                fatalError("Failed to start plugin \(plugin.key)! Error: \(error)")
            }
        }
    }

    /// Stops all plugins in the *reversed* order as they were added.
    // @available(*, deprecated, message: "use 'actor cluster' transport version instead") // TODO: deprecate
    internal func stopAll(_ system: ClusterSystem) async {
        // Shut down in reversed order so plugins with the fewest dependencies are stopped first!
        for plugin in self.plugins.reversed() {
            await plugin.stop(system)
        }
    }
}

extension PluginsSettings {
    /// Installs the passed in plugin in the settings.
    ///
    /// The plugin will be started as the actor system becomes fully initialized,
    /// and stopped as the system is shut down.
    ///
    /// - Parameter plugin: plugin to install in the actor system
    public mutating func install<P: _Plugin>(plugin: P) {
        precondition(
            !self.plugins.contains(where: { $0.key == plugin.key.asAny }),
            "Attempted to add plugin \(plugin.key) but key already used! Plugin [\(plugin)], installed plugins: \(self.plugins)."
        )

        return self.plugins.append(BoxedPlugin(plugin))
    }

    @available(*, deprecated, message: "use settings.install(plugin:) instead")
    public static func += <P: _Plugin>(plugins: inout PluginsSettings, plugin: P) {
        plugins.add(plugin)
    }
}

extension ClusterSystemSettings {
    public static func += <P: _Plugin>(settings: inout ClusterSystemSettings, plugin: P) {
        settings.plugins.add(plugin)
    }
}
