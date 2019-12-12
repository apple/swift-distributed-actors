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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton

/// An `ActorSingleton` ensures that there is no more than one actor of a specific type running in the cluster.
///
/// Actor types that are singleton must be registered during system setup, as part of `ActorSingletonPluginSettings`.
/// The `ActorRef` of the singleton can later be obtained through `ActorSystem.singleton.ref(name:)`.
///
/// A singleton may run on any node in the cluster. Use `ActorSingletonSettings.allocationStrategy` to control node
/// allocation. The `ActorRef` returned by `ref(name:)` is actually a proxy in order to handle situations where the
/// singleton is shifted to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///    the singleton allocation.
public class ActorSingleton<Message> {
    /// Settings for the `ActorSingleton`
    public let settings: ActorSingletonSettings

    /// Props of singleton behavior
    public let props: Props
    /// The singleton behavior
    public let behavior: Behavior<Message>

    /// The manager ref
    internal private(set) var manager: ActorRef<ActorSingletonManager<Message>.ManagerMessage>!

    /// The proxy ref
    internal private(set) var proxy: ActorRef<Message>!

    /// Defines a `behavior` as singleton with `settings`.
    public init(settings: ActorSingletonSettings, props: Props = Props(), _ behavior: Behavior<Message>) {
        self.settings = settings
        self.props = props
        self.behavior = behavior
    }

    /// Defines a `behavior` as singleton identified by `name`.
    public convenience init(_ name: String, props: Props = Props(), _ behavior: Behavior<Message>) {
        let settings = ActorSingletonSettings(name: name)
        self.init(settings: settings, props: props, behavior)
    }

    /// Spawns `ActorSingletonProxy` and associated actors (e.g., `ActorSingleManager`).
    internal func spawnProxy(_ system: ActorSystem) throws {
        let allocationStrategy = self.settings.allocationStrategy.make(system.settings.cluster, self.settings)
        let manager = try system.spawn(
            "$singletonManager-\(self.settings.name)",
            ActorSingletonManager(settings: self.settings, allocationStrategy: allocationStrategy, props: self.props, self.behavior).behavior
        )
        self.manager = manager

        self.proxy = try system.spawn(
            "$singletonProxy-\(self.settings.name)",
            ActorSingletonProxy(settings: self.settings, manager: manager).behavior
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Type-erased `ActorSingleton`

internal protocol AnyActorSingleton {
    func spawnProxy(_ system: ActorSystem) throws
}

extension ActorSingleton: AnyActorSingleton {}

internal struct BoxedActorSingleton: AnyActorSingleton {
    private let underlying: AnyActorSingleton

    init<Message>(_ actorSingleton: ActorSingleton<Message>) {
        self.underlying = actorSingleton
    }

    internal func spawnProxy(_ system: ActorSystem) throws {
        try self.underlying.spawnProxy(system)
    }

    internal func unsafeUnwrapAs<Message>(_: Message.Type) -> ActorSingleton<Message> {
        guard let unwrapped = self.underlying as? ActorSingleton<Message> else {
            fatalError("Type mismatch, expected: [\(String(reflecting: ActorSingleton<Message>.self))] got [\(self.underlying)]")
        }
        return unwrapped
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingleton settings

/// Settings for a `ActorSingleton`.
public struct ActorSingletonSettings {
    /// Unique name for the singleton
    public let name: String

    /// Capacity of temporary message buffer in case singleton is unavailable.
    /// If the buffer becomes full, the *oldest* messages would be disposed to make room for the newer messages.
    public var bufferCapacity: Int = 2048 {
        willSet(newValue) {
            precondition(newValue > 0, "bufferCapacity must be greater than 0")
        }
    }

    /// Controls allocation of the node on which the singleton runs.
    public var allocationStrategy: AllocationStrategySettings = .leadership

    public init(name: String) {
        self.name = name
    }
}

/// Singleton node allocation strategies.
public enum AllocationStrategySettings {
    /// Singletons will run on the cluster leader
    case leadership

    func make(_: ClusterSettings, _: ActorSingletonSettings) -> AllocationStrategy {
        switch self {
        case .leadership:
            return AllocationByLeadership()
        }
    }
}
