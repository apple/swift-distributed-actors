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
public struct PluginsSettings {
    public static var `default`: PluginsSettings {
        .init()
    }

    internal var plugins: [BoxedPlugin] = []

    public init() {}

    /// Adds a `Plugin`.
    ///
    /// - Note: A plugin that depends on others should be added *after* its dependencies.
    /// - Faults, when plugin of the exact same `PluginKey` is already included in the settings.
    public mutating func add<P: _Plugin>(_ plugin: P) {
        precondition(
            !self.plugins.contains(where: { $0.key == plugin.key.asAny }),
            "Attempted to add plugin \(plugin.key) but key already used! Plugin [\(plugin)], installed plugins: \(self.plugins)."
        )

        return self.plugins.append(BoxedPlugin(plugin))
    }

    /// Returns `Plugin` identified by `key`.
    public subscript<P: _Plugin>(_ key: _PluginKey<P>) -> P? {
        self.plugins.first { $0.key == key.asAny }?.unsafeUnwrapAs(P.self)
    }

    /// Starts all plugins in the same order as they were added.
    internal func startAll(_ system: ClusterSystem) async {
        for plugin in self.plugins {
            do {
                try await plugin.start(system)
            } catch {
                fatalError("Failed to start plugin \(plugin.key)! Error: \(error)")
            }
        }
    }

    /// Stops all plugins in the *reversed* order as they were added.
    // @available(*, deprecated, message: "use 'actor cluster' transport version instead") // TODO: deprecate
    internal func stopAll(_ system: ClusterSystem) {
        // Shut down in reversed order so plugins with the fewest dependencies are stopped first!
        for plugin in self.plugins.reversed() {
            plugin.stop(system)
        }
    }

//    /// Stops all plugins in the *reversed* order as they were added.
//    internal func stopAll(_ transport: ActorClusterTransport) async {
//        // Shut down in reversed order so plugins with the fewest dependencies are stopped first!
//        for plugin in self.plugins.reversed() {
//            do {
//                try await plugin.stop(transport)
//            } catch {
//                fatalError("Failed to stop plugin \(plugin.key)! Error: \(error)")
//            }
//        }
//    }
}

extension PluginsSettings {
    public static func += <P: _Plugin>(plugins: inout PluginsSettings, plugin: P) {
        plugins.add(plugin)
    }
}

extension ClusterSystemSettings {
    public static func += <P: _Plugin>(settings: inout ClusterSystemSettings, plugin: P) {
        settings.plugins.add(plugin)
    }
}
