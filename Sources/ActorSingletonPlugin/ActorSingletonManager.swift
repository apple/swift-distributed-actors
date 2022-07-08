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

import Distributed
import DistributedActors
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager

/// Spawned as a system actor on the node where the singleton is supposed to run, `ActorSingletonManager` manages
/// the singleton's lifecycle and hands over the singleton when it terminates.
internal distributed actor ActorSingletonManager<Act: DistributedActor> where Act.ActorSystem == ClusterSystem {
    typealias ActorSystem = ClusterSystem

    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    let singletonProps: _Props
    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let singletonFactory: (ClusterSystem) async throws -> Act

    /// The singleton
    private var singleton: Act?

    private lazy var log = Logger(actor: self)

    init(
        settings: ActorSingletonSettings,
        system: ActorSystem,
        singletonProps: _Props,
        _ singletonFactory: @escaping (ClusterSystem) async throws -> Act
    ) {
        self.actorSystem = system
        self.settings = settings
        self.singletonProps = singletonProps
        self.singletonFactory = singletonFactory
    }

    deinit {
        // FIXME: should hand over
        // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
//        try self.handOver(to: nil)
    }

    func takeOver(from: UniqueNode?) async throws -> Act {
        self.log.debug("Take over singleton [\(self.settings.name)] from [\(String(describing: from))]", metadata: self.metadata())

        // TODO: (optimization) tell `ActorSingletonManager` on `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        let singleton = try await _Props.$forSpawn.withValue(self.singletonProps._knownAs(name: self.settings.name)) {
            try await self.singletonFactory(self.actorSystem)
        }
        self.singleton = singleton
        return singleton
    }

    func handOver(to: UniqueNode?) throws {
        self.log.debug("Hand over singleton [\(self.settings.name)] to [\(String(describing: to))]", metadata: self.metadata())

        // TODO: (optimization) tell `ActorSingletonManager` on `to` node that this node is handing off (https://github.com/apple/swift-distributed-actors/issues/329)
        self.singleton = nil
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logging

extension ActorSingletonManager {
    func metadata() -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "name": "\(self.settings.name)",
        ]

        if let singleton = self.singleton {
            metadata["singleton"] = "\(singleton)"
        }

        return metadata
    }
}
