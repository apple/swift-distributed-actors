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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ConvergentGossip Settings

extension ConvergentGossip {
    struct Settings {
        /// Interval at which gossip rounds should proceed.
        var gossipInterval: TimeAmount = .seconds(1)

        // TODO: slight jitter to the gossip rounds?

        /// Invoked during each gossip "round" right before a payload is to be gossiped to peers.
        ///
        /// The returned value will be used as the gossip round's payload, and stored for future gossip rounds.
        /// This allows the system to modify the payload each time (e.g. to (inc-)decrement a counter etc.
        ///
        /// Returning `nil` results in the
        /// // TODO rather we should return a directive here? .lastGossip(), .gossip(), .remove() etc?
        /// // TODO we need different Storage and Payload and a Storage -> Payload I guess as we do not want to send the "send 3 more times" information
        var onGossipRound: (Payload) -> Payload? = { payload in
            payload
        }

        /// Configure how peers should be discovered and added to the gossip group.
        ///
        /// By default, the gossiper does not know how to locate its peers, and a key can be passed in to make it
        /// use the `Receptionist` to (register itself and) locate its peers.
        ///
        /// Peers may be added manually by sending the `introduce` message at any time, the gossiper will NOT reject such
        /// introduced peer, even if operating in an auto-discovery mode (may be useful to inject a test listener probe into the gossip group).
        var peerDiscovery: PeerDiscovery = .manuallyIntroduced
        enum PeerDiscovery {
            case fromReceptionistListing(key: Receptionist.RegistrationKey<Message>)
//            /// Automatically discover and add cluster members to the gossip group when they become reachable in `atLeast` status.
//            ///
//            /// Note that by default `.leaving`, `.down` and `.removed` members are NOT added to the gossip group,
//            /// even if they were never contacted by this gossiper before.
//            case onClusterMember(atLeast: Cluster.MemberStatus, resolve: (Cluster.Member) -> AddressableActorRef)

            /// Peers have to be manually introduced by calling `control.introduce()` on to the gossiper.
            /// This gives full control about when a peer should join the gossip group, however usually is not necessary
            /// as one can normally rely on the cluster events (e.g. a member becoming `.up`) to join the group which is
            case manuallyIntroduced
        }

        // TODO: configurable who to gossip to
        /// var gossipTargetSelection: PeerSelection = .random
    }
}
