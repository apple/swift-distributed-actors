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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Plugin protocol

public protocol _AnyPlugin {
    /// Starts the plugin.
    func start(_ system: ClusterSystem) async throws

    /// Stops the plugin.
    func stop(_ system: ClusterSystem) async
}

/// A plugin provides specific features and capabilities (e.g., singleton) to a `ClusterSystem`.
public protocol _Plugin: _AnyPlugin {
    typealias Key = _PluginKey<Self>

    /// The plugin's unique identifier
    var key: Key { get }
}

internal struct BoxedPlugin: _AnyPlugin {
    private let underlying: _AnyPlugin

    let key: AnyPluginKey

    init<P: _Plugin>(_ plugin: P) {
        self.underlying = plugin
        self.key = AnyPluginKey(plugin.key)
    }

    func unsafeUnwrapAs<P: _Plugin>(_: P.Type) -> P {
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

public struct _PluginKey<P: _Plugin>: CustomStringConvertible, ExpressibleByStringLiteral {
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

    public func makeSub(_ sub: String) -> _PluginKey {
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

    init<P: _Plugin>(_ key: _PluginKey<P>) {
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
public protocol PluginActorLifecycleHook {
    func actorReady<Act: DistributedActor>(_ actor: Act) where Act: DistributedActor, Act.ID == ClusterSystem.ActorID
    func resignID(_ id: ClusterSystem.ActorID)
}
