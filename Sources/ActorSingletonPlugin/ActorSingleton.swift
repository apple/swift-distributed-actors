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

/// An `ActorSingleton` ensures that there is no more than one instance of an actor running in the cluster.
///
/// Actors that are singleton must be registered during system setup, as part of `ActorSystemSettings`.
/// The `ActorRef` of the singleton can later be obtained through `ActorSystem.singleton.ref(name:)`.
///
/// A singleton may run on any node in the cluster. Use `ActorSingletonSettings.allocationStrategy` to control node
/// allocation. The `ActorRef` returned by `ref(name:)` is actually a proxy in order to handle situations where the
/// singleton is shifted to different nodes.
///
/// - Warning: Refer to the configured `AllocationStrategy` for trade-offs between safety and recovery latency for
///   the singleton allocation.
/// - SeeAlso: The `ActorSingleton` mechanism conceptually similar to Erlang/OTP's <a href="http://erlang.org/doc/design_principles/distributed_applications.html">`DistributedApplication`</a>,
//             and <a href="https://doc.akka.io/docs/akka/current/cluster-singleton.html">`ClusterSingleton` in Akka</a>.
public final class ActorSingleton<Message> {
    /// Settings for the `ActorSingleton`
    public let settings: ActorSingletonSettings

    /// Props of singleton behavior
    public let props: Props
    /// The singleton behavior
    public let behavior: Behavior<Message>

    /// The `ActorSingletonProxy` ref
    internal private(set) var proxy: ActorRef<Message>?

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
    internal func spawnAll(_ system: ActorSystem) throws {
        let allocationStrategy = self.settings.allocationStrategy.make(system.settings.cluster, self.settings)
        self.proxy = try system._spawnSystemActor(
            "singletonProxy-\(self.settings.name)",
            ActorSingletonProxy(settings: self.settings, allocationStrategy: allocationStrategy, props: self.props, self.behavior).behavior,
            props: ._wellKnown
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol conformance

extension ActorSingleton: Plugin {
    public static func pluginKey(name: String) -> PluginKey<ActorSingleton<Message>> {
        PluginKey<ActorSingleton<Message>>(plugin: "$actorSingleton").makeSub(name)
    }

    public var key: PluginKey<ActorSingleton<Message>> {
        Self.pluginKey(name: self.settings.name)
    }

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        do {
            try self.spawnAll(system)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // TODO: Future
    public func stop(_ system: ActorSystem) -> Result<Void, Error> {
        // Hand over the singleton gracefully
        let resolveContext = ResolveContext<ActorSingletonManager<Message>.Directive>(address: ._singletonManager(name: self.settings.name), system: system)
        let managerRef = system._resolve(context: resolveContext)
        managerRef.tell(.stop)

        // We don't control the proxy's directives so we can't tell it to stop
        return .success(())
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

    func make(_: ClusterSettings, _: ActorSingletonSettings) -> ActorSingletonAllocationStrategy {
        switch self {
        case .leadership:
            return ActorSingletonAllocationByLeadership()
        }
    }
}
