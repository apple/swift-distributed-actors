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
    public var allocationStrategy: AllocationStrategySettings = .byLeadership

    /// Time to wait for the singleton, whether allocated on this node or another, before
    /// we stop stashing calls and throw error.
    public var allocationTimeout: Duration = .seconds(30)

    public init() {}
}

/// Singleton node allocation strategies.
public struct AllocationStrategySettings {
    private enum AllocationStrategy {
        /// Singletons will run on the cluster leader. *All* nodes are potential candidates.
        case byLeadership
    }

    private var allocationStrategy: AllocationStrategy

    private init(allocationStrategy: AllocationStrategy) {
        self.allocationStrategy = allocationStrategy
    }

    func makeAllocationStrategy(_: ClusterSystemSettings, _: ClusterSingletonSettings) -> ClusterSingletonAllocationStrategy {
        switch self.allocationStrategy {
        case .byLeadership:
            return ClusterSingletonAllocationByLeadership()
        }
    }

    public static let byLeadership: AllocationStrategySettings = .init(allocationStrategy: .byLeadership)
}
