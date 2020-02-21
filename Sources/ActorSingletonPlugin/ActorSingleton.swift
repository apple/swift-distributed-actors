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

internal final class ActorSingleton<Message> {
    /// Settings for the `ActorSingleton`
    let settings: ActorSingletonSettings

    /// Props of singleton behavior
    let props: Props?
    /// The singleton behavior.
    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let behavior: Behavior<Message>?

    /// The `ActorSingletonProxy` ref
    internal private(set) var proxy: ActorRef<Message>?

    init(settings: ActorSingletonSettings, props: Props?, _ behavior: Behavior<Message>?) {
        self.settings = settings
        self.props = props
        self.behavior = behavior
    }

    /// Spawns `ActorSingletonProxy` and associated actors (e.g., `ActorSingletonManager`).
    func spawnAll(_ system: ActorSystem) throws {
        let allocationStrategy = self.settings.allocationStrategy.make(system.settings.cluster, self.settings)
        self.proxy = try system._spawnSystemActor(
            "singletonProxy-\(self.settings.name)",
            ActorSingletonProxy(settings: self.settings, allocationStrategy: allocationStrategy, props: self.props, self.behavior).behavior,
            props: ._wellKnown
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Type-erased actor singleton

internal protocol AnyActorSingleton {
    /// Stops the `ActorSingletonProxy` running in the `system`.
    /// If `ActorSingletonManager` is also running, which means the actual singleton is hosted
    /// on this node, it will attempt to hand-over the singleton gracefully before stopping.
    func stop(_ system: ActorSystem)
}

internal struct BoxedActorSingleton: AnyActorSingleton {
    private let underlying: AnyActorSingleton

    init<Message>(_ actorSingleton: ActorSingleton<Message>) {
        self.underlying = actorSingleton
    }

    func unsafeUnwrapAs<Message>(_ type: Message.Type) -> ActorSingleton<Message> {
        guard let unwrapped = self.underlying as? ActorSingleton<Message> else {
            fatalError("Type mismatch, expected: [\(String(reflecting: ActorSingleton<Message>.self))] got [\(self.underlying)]")
        }
        return unwrapped
    }

    func stop(_ system: ActorSystem) {
        self.underlying.stop(system)
    }
}

extension ActorSingleton: AnyActorSingleton {
    func stop(_ system: ActorSystem) {
        // Hand over the singleton gracefully
        let resolveContext = ResolveContext<ActorSingletonManager<Message>.Directive>(address: ._singletonManager(name: self.settings.name), system: system)
        let managerRef = system._resolve(context: resolveContext)
        // If the manager is not running this will end up in dead-letters but that's fine
        managerRef.tell(.stop)

        // We don't control the proxy's directives so we can't tell it to stop
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton settings

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
    public var allocationStrategy: AllocationStrategySettings = .byLeadership

    public init(name: String) {
        self.name = name
    }
}

/// Singleton node allocation strategies.
public enum AllocationStrategySettings {
    /// Singletons will run on the cluster leader. *All* nodes are potential candidates.
    case byLeadership

    func make(_: ClusterSettings, _: ActorSingletonSettings) -> ActorSingletonAllocationStrategy {
        switch self {
        case .byLeadership:
            return ActorSingletonAllocationByLeadership()
        }
    }
}
