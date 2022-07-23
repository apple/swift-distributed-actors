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

/// Settings for a `ClusterSingleton`.
public struct ClusterSingletonSettings {
    /// Unique name for the singleton, used to identify the conceptual singleton in the cluster.
    /// E.g. there is always one "boss" instance in the cluster, regardless where it is incarnated.
    ///
    /// The name property is set on a settings object while creating a singleton reference (e.g. using `host` or `proxy`).
    public internal(set) var name: String = ""

    /// Capacity of temporary message buffer in case singleton is unavailable.
    /// If the buffer becomes full, the *oldest* messages would be disposed to make room for the newer messages.
    public var bufferCapacity: Int = 2048 {
        willSet(newValue) {
            precondition(newValue > 0, "bufferCapacity must be greater than 0")
        }
    }

    /// Controls allocation of the node on which the singleton runs.
    public var allocationStrategy: ClusterSingletonAllocationStrategySettings = .byLeadership

    /// Time to wait for the singleton, whether allocated on this node or another, before
    /// we stop stashing calls and throw error.
    public var allocationTimeout: Duration = .seconds(30)

    public init() {}
}

/// Singleton node allocation strategies.
public struct ClusterSingletonAllocationStrategySettings {
    private enum AllocationStrategy {
        /// Singletons will run on the cluster leader. *All* nodes are potential candidates.
        case byLeadership

        /// Custom strategy, allowing end-users to develop their own strategies
        case custom(@Sendable (ClusterSingletonSettings, ClusterSystem) async -> any ClusterSingletonAllocationStrategy)
    }

    private var allocationStrategy: AllocationStrategy

    private init(allocationStrategy: AllocationStrategy) {
        self.allocationStrategy = allocationStrategy
    }

    func makeAllocationStrategy(settings: ClusterSingletonSettings,
                                actorSystem: ClusterSystem) async -> ClusterSingletonAllocationStrategy
    {
        switch self.allocationStrategy {
        case .byLeadership:
            return ClusterSingletonAllocationByLeadership(settings: settings, actorSystem: actorSystem)
        case .custom(let make):
            return await make(settings, actorSystem)
        }
    }
}

extension ClusterSingletonAllocationStrategySettings {
    /// The singleton instance will be hosted on an `.up` leader member of the cluster.
    public static let byLeadership: ClusterSingletonAllocationStrategySettings =
        .init(allocationStrategy: .byLeadership)

    /// Custom strategy.
    public static func custom<Strategy>(_ make: @Sendable @escaping (ClusterSingletonSettings, ClusterSystem) async -> Strategy) -> ClusterSingletonAllocationStrategySettings where Strategy: ClusterSingletonAllocationStrategy {
        .init(allocationStrategy: .custom(make))
    }
}
