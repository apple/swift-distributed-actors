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
// MARK: Cluster singleton

/// Cluster singleton ensures that there is no more than one actor of a specific type running in the cluster.
///
/// Actor types that are cluster singletons must be registered during system setup, by calling `ActorSystemSettings.plugins.add(clusterSingleton:)`.
/// The `ActorRef` of the cluster singleton can later be obtained by calling `ActorSystem.plugins.clusterSingleton.ref(name:)`.
///
/// A cluster singleton may run on any node in the cluster. Use `ClusterSingletonSettings.allocationStrategy` to control node allocation.
/// The `ActorRef` returned by `ref(name:)` is actually a proxy in order to handle situations where the singleton is shifted to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for tradeoffs between safety and recovery latency for the singleton allocation.
public class ClusterSingleton {
    public let settings: ClusterSingletonSettings

    /// The function that spawns the proxy and any associated actors and returns its `ActorRef`
    internal let _spawnProxy: (ActorSystem) throws -> ReceivesSystemMessages

    /// The proxy's `ActorRef`
    internal var proxy: ReceivesSystemMessages?

    /// Defines a `behavior` as cluster singleton with `settings`.
    public init<Message>(settings: ClusterSingletonSettings, props: Props = Props(), _ behavior: Behavior<Message>) {
        self.settings = settings
        self._spawnProxy = { system in
            let allocationStrategy = settings.allocationStrategy.make(system.settings.cluster, settings)
            let manager = try system.spawn(
                "$singletonManager-\(settings.name)",
                ClusterSingletonManager(settings: settings, allocationStrategy: allocationStrategy, props: props, behavior).behavior
            )

            return try system.spawn("$singletonProxy-\(settings.name)", ClusterSingletonProxy(settings: settings, manager: manager).behavior)
        }
    }

    /// Defines a `behavior` as cluster singleton identified by `name`.
    public convenience init<Message>(_ name: String, props: Props = Props(), _ behavior: Behavior<Message>) {
        let settings = ClusterSingletonSettings(name: name)
        self.init(settings: settings, props: props, behavior)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingleton settings

/// Settings for a `ClusterSingleton`.
public struct ClusterSingletonSettings {
    /// Unique name for the cluster singleton
    public let name: String

    /// Capacity of temporary message buffer in case cluster singleton is unavailable.
    /// If the buffer becomes full, the *oldest* messages would be disposed to make room for the newer messages.
    public var bufferCapacity: Int = 2048 {
        willSet(newValue) {
            precondition(newValue > 0, "bufferCapacity must be greater than 0")
        }
    }

    /// Controls allocation of the node on which the cluster singleton runs.
    public var allocationStrategy: AllocationStrategySettings = .leadership

    public init(name: String) {
        self.name = name
    }
}

/// Cluster singleton node allocation strategies.
public enum AllocationStrategySettings {
    /// Cluster singletons will run on the cluster leader
    case leadership

    func make(_: ClusterSettings, _: ClusterSingletonSettings) -> AllocationStrategy {
        switch self {
        case .leadership:
            return AllocationByLeadership()
        }
    }
}
