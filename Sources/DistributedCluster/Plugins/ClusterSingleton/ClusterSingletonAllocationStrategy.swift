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
// MARK: Protocol for singleton allocation strategy

/// Strategy for choosing a `Cluster.Node` to allocate singleton.
public protocol ClusterSingletonAllocationStrategy {
    /// Receives and handles the `Cluster.Event`.
    ///
    /// - Returns: The current `node` after processing `clusterEvent`.
    func onClusterEvent(_ clusterEvent: Cluster.Event) async -> Cluster.Node?

    /// The currently allocated `node` for the singleton.
    var node: Cluster.Node? { get async }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingletonAllocationStrategy implementations

/// An `AllocationStrategy` in which selection is based on cluster leadership.
public final class ClusterSingletonAllocationByLeadership: ClusterSingletonAllocationStrategy {
    var _node: Cluster.Node?

    public init(settings: ClusterSingletonSettings, actorSystem: ClusterSystem) {
        // not used...
    }

    public func onClusterEvent(_ clusterEvent: Cluster.Event) async -> Cluster.Node? {
        switch clusterEvent {
        case .leadershipChange(let change):
            self._node = change.newLeader?.node
        case .snapshot(let membership):
            self._node = membership.leader?.node
        default:
            ()  // ignore other events
        }
        return self._node
    }

    public var node: Cluster.Node? {
        get async {
            self._node
        }
    }
}

// TODO: "oldest node"

// TODO: "race to become the host", all nodes race and try CAS-like to set themselves as leader -- this we could do with cas-paxos perhaps or similar; it is less predictable which node wins, which can be good or bad
