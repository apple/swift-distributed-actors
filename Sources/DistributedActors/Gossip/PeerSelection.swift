//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Peer Selection is a common step in various gossip protocols.
///
/// Selecting a peer may be as trivial as randomly selecting one among known actors or nodes,
/// round-robin cycling through peers or a mix thereof in which the order is randomized _but stable_
/// which reduces the risk of gossiping to the same or starving certain peers in situations when many
/// new peers are added to the group.
/// // TODO: implement SWIMs selection in terms of this
public protocol PeerSelection {
    associatedtype Peer: Hashable
    typealias Peers = [Peer]

    func onMembershipEvent(event: Cluster.Event)

    func select() -> Peers
}
