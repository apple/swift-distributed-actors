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
// MARK: Cluster singleton "boss"

/// Spawned on the node where the singleton is supposed to run, `ClusterSingletonBoss` manages
/// the singleton's lifecycle and hands over the singleton when it terminates.
internal distributed actor ClusterSingletonBoss<Act: DistributedActor> where Act.ActorSystem == ClusterSystem {
    typealias ActorSystem = ClusterSystem

    private let settings: ClusterSingletonSettings

    let singletonProps: _Props
    let singletonFactory: (ClusterSystem) async throws -> Act

    /// The singleton
    private var singleton: Act?

    private lazy var log = Logger(actor: self)

    init(
        settings: ClusterSingletonSettings,
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
        // FIXME: should hand over but it's async call
        // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
//        try self.handOver(to: nil)
    }

    func takeOver(from: UniqueNode?) async throws -> Act {
        self.log.debug("Take over singleton [\(self.settings.name)] from [\(String(describing: from))]", metadata: self.metadata())

        // TODO: (optimization) tell `ClusterSingletonBoss` on `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        let singleton = try await _Props.$forSpawn.withValue(self.singletonProps.singleton(settings: self.settings)) {
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

extension ClusterSingletonBoss {
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
