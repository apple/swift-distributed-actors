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

// public struct StableRandomRoundRobin<Peer: Hashable> {
//
//    var peerSet: Set<Peer>
//    var peers: [Peer]
//
//    // how many peers we select in each gossip round,
//    // we could for example be dynamic and notice if we have 10+ nodes, we pick 2 members to speed up the dissemination etc.
//    let n = 1
//
//    public init() {
//    }
//
//    func onMembershipEvent(event: Cluster.Event) {
//
//    }
//
//    func update(peers newPeers: [Peer]) {
//        let newPeerSet = Set(peers)
//    }
//
//    func select() -> [Peer] {
//        var selectedPeers: [AddressableActorRef] = []
//        selectedPeers.reserveCapacity(n)
//
//        for peer in peers.shuffled()
//            where selectedPeers.count < n && self.shouldGossipWith(peer) {
//            selectedPeers.append(peer)
//        }
//
//        return selectedPeers
//    }
//
// }
