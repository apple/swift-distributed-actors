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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protocol for cluster singleton allocation strategy

/// Strategy for choosing a `UniqueNode` to allocate cluster singleton.
internal protocol AllocationStrategy {
    /// Receives and handles the `clusterEvent`.
    ///
    /// - Returns: The current `node` after processing `clusterEvent`.
    func onClusterEvent(_ clusterEvent: ClusterEvent) -> UniqueNode?

    /// The currently allocated `node` for the cluster singleton.
    var node: UniqueNode? { get }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AllocationStrategy implementations

/// An `AllocationStrategy` in which selection is based on cluster leadership.
internal class AllocationByLeadership: AllocationStrategy {
    var node: UniqueNode?

    init() {}

    func onClusterEvent(_ clusterEvent: ClusterEvent) -> UniqueNode? {
        switch clusterEvent {
        case .leadershipChange(let change):
            self.node = change.newLeader?.node
        case .snapshot(let membership):
            self.node = membership.leader?.node
        default:
            () // ignore other events
        }
        return self.node
    }
}
