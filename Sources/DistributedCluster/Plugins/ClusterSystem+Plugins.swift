//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol

public protocol AnyPlugin {
    /// Starts the plugin.
    func start(_ system: ClusterSystem) async throws

    /// Stops the plugin.
    func stop(_ system: ClusterSystem) async
}

/// A plugin provides specific features and capabilities (e.g., singleton) to a `ClusterSystem`.
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

    func start(_ system: ClusterSystem) async throws {
        try await self.underlying.start(system)
    }

    func stop(_ system: ClusterSystem) async {
        await self.underlying.stop(system)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin key

public struct PluginKey<P: Plugin>: CustomStringConvertible, ExpressibleByStringLiteral {
    public let plugin: String
    public let sub: String?

    internal var asAny: AnyPluginKey {
        AnyPluginKey(self)
    }

    public init(id plugin: String) {
        self.init(plugin: plugin, sub: nil)
    }

    public init(stringLiteral: StringLiteralType) {
        self.init(id: stringLiteral)
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

/// Kind of `ClusterSystem` plugin which will be invoked during an actor's `actorReady`
/// and `resignID` lifecycle hooks.
///
/// The ready hook is allowed to modify the ID, e.g. by adding additional metadata to it.
/// The plugin should carefully manage retaining actors and document if it does have strong references to them,
/// and how end-users should go about releasing them.
public protocol ActorLifecyclePlugin: Plugin {
    func onActorReady<Act: DistributedActor>(_ actor: Act) where Act: DistributedActor, Act.ID == ClusterSystem.ActorID
    func onResignID(_ id: ClusterSystem.ActorID)
}
