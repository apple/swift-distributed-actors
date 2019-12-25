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
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager

/// Spawned as a system actor on the node where the singleton is supposed to run, `ActorSingletonManager` manages
/// the singleton's lifecycle and stops itself after handing over the singleton.
internal class ActorSingletonManager<Message> {
    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// Props of the singleton behavior
    private let singletonProps: Props
    /// The singleton behavior
    private let singletonBehavior: Behavior<Message>

    /// The singleton ref
    private var singleton: ActorRef<Message>?

    init(settings: ActorSingletonSettings, props: Props, _ behavior: Behavior<Message>) {
        self.settings = settings
        self.singletonProps = props
        self.singletonBehavior = behavior
    }

    var behavior: Behavior<Directive> {
        Behavior<Directive>.receive { context, message in
            switch message {
            case .takeOver(let from, let replyTo):
                // Spawn the singleton then send its ref
                try self.takeOver(context, from: from)
                replyTo.tell(self.singleton)
                return .same
            case .handOver(let to):
                // Hand over the singleton then stop myself as a result of singleton node change
                try self.handOver(context, to: to)
                return .stop
            case .stop:
                // Hand over the singleton then stop myself as part of system shutdown
                try self.handOver(context, to: nil)
                return .stop
            }
        }
    }

    private func takeOver(_ context: ActorContext<Directive>, from: UniqueNode?) throws {
        // TODO: (optimization) tell `ActorSingletonManager` on `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        self.singleton = try context.spawn(.unique(self.settings.name), props: self.singletonProps, self.singletonBehavior)
    }

    private func handOver(_ context: ActorContext<Directive>, to: UniqueNode?) throws {
        // TODO: (optimization) tell `ActorSingletonManager` on `to` node that this node is handing off (https://github.com/apple/swift-distributed-actors/issues/329)
        guard let singleton = self.singleton else {
            return
        }
        try context.stop(child: singleton)
    }

    internal enum Directive {
        case takeOver(from: UniqueNode?, replyTo: ActorRef<ActorRef<Message>?>)
        case handOver(to: UniqueNode?)
        case stop
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager + logging

extension ActorSingletonManager {
    func metadata<Directive>(_: ActorContext<Directive>) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "name": "\(self.settings.name)",
        ]

        if let singleton = self.singleton {
            metadata["singleton"] = "\(singleton)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager path / address

extension ActorAddress {
    internal static func _singletonManager(name: String, on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._singletonManager(name: name), incarnation: .wellKnown)
    }

    internal static func _singletonManager(name: String) -> ActorAddress {
        .init(path: ._singletonManager(name: name), incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static func _singletonManager(name: String) -> ActorPath {
        try! ActorPath._system.appending("singletonManager-\(name)")
    }
}
