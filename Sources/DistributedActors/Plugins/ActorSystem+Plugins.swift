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

/// A plugin provides specific features and capabilities (e.g., cluster singleton) to an `ActorSystem`.
internal protocol Plugin {
    /// The plugin's unique identifier
    static var name: String { get }

    // TODO: introduce ActorSystem lifecycle and make plugin a lifecycle item?

    /// Delegate that gets called during `ActorSystem.init`
    func onSystemInit(_ system: ActorSystem) -> Result<Void, Error>

    /// Delegate that gets called at the end of `ActorSystem.init`
    func onSystemInitComplete(_ system: ActorSystem) -> Result<Void, Error>

    /// Delegate that gets called during `ActorSystem.shutdown`
    func onSystemShutdown(_ system: ActorSystem) -> Result<Void, Error>
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugins

/// A collection of `Plugin`s for an `ActorSystem`.
internal class Plugins {
    /// Plugins by identifier
    private var plugins: [String: Plugin] = [:]

    init(settings: PluginsSettings) {
        self.plugins[ClusterSingletonPlugin.name] = ClusterSingletonPlugin(settings: settings.clusterSingleton)
    }

    /// Returns `Plugin` for the `identifier`.
    subscript(_ identifier: String) -> Plugin? {
        self.plugins[identifier]
    }

    /// Calls `onSystemInit` on each plugin.
    func onSystemInit(_ system: ActorSystem) {
        for (key, plugin) in self.plugins {
            if case .failure(let error) = plugin.onSystemInit(system) {
                fatalError("Failed to initialize plugin \(key)! Error: \(error)")
            }
        }
    }

    /// Calls `onSystemInitComplete` on each plugin.
    func onSystemInitComplete(_ system: ActorSystem) {
        for (key, plugin) in self.plugins {
            if case .failure(let error) = plugin.onSystemInitComplete(system) {
                fatalError("Failed to complete initialization for plugin \(key)! Error: \(error)")
            }
        }
    }

    /// Calls `onSystemShutdown` on each plugin.
    func onSystemShutdown(_ system: ActorSystem) {
        for (key, plugin) in self.plugins {
            if case .failure(let error) = plugin.onSystemShutdown(system) {
                fatalError("Failed to shut down plugin \(key)! Error: \(error)")
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugins settings

/// Configures `ActorSystem` plugins.
public struct PluginsSettings {
    public static var `default`: PluginsSettings {
        .init()
    }

    public var clusterSingleton: ClusterSingletonPluginSettings = .default

    public init() {}

    /// Adds a `ClusterSingleton`.
    public mutating func add(_ clusterSingleton: ClusterSingleton) -> Result<Void, ClusterSingletonError> {
        return self.clusterSingleton.add(clusterSingleton)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin shortcuts

extension Plugins {
    public var clusterSingleton: ClusterSingletonPlugin {
        guard let singleton = self[ClusterSingletonPlugin.name], let clusterSingleton = singleton as? ClusterSingletonPlugin else {
            fatalError("Invalid plugin [\(ClusterSingletonPlugin.name)]")
        }
        return clusterSingleton
    }
}
