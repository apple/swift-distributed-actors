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
// MARK: Protocol for singleton allocation strategy

/// Strategy for choosing a `UniqueNode` to allocate singleton.
internal protocol ActorSingletonAllocationStrategy {
    /// Receives and handles the `clusterEvent`.
    ///
    /// - Returns: The current `node` after processing `clusterEvent`.
    func onClusterEvent(_ clusterEvent: Cluster.Event) -> UniqueNode?

    /// The currently allocated `node` for the singleton.
    var node: UniqueNode? { get }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AllocationStrategy implementations

/// An `AllocationStrategy` in which selection is based on cluster leadership.
internal class ActorSingletonAllocationByLeadership: ActorSingletonAllocationStrategy {
    var node: UniqueNode?

    init() {}

    func onClusterEvent(_ clusterEvent: Cluster.Event) -> UniqueNode? {
        switch clusterEvent {
        case .leadershipChange(let change):
            self.node = change.newLeader?.uniqueNode
        case .snapshot(let membership):
            self.node = membership.leader?.uniqueNode
        default:
            () // ignore other events
        }
        return self.node
    }
}

// TODO: "oldest node"

// TODO: "race to become the host", all nodes race and try CAS-like to set themselves as leader -- this we could do with cas-paxos perhaps or similar; it is less predictable which node wins, which can be good or bad
