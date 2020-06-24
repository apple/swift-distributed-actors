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
// MARK: Gossiper Settings

extension Gossiper {
    public struct Settings {
        /// Interval at which gossip rounds should proceed.
        public var gossipInterval: TimeAmount = .seconds(2)

        /// Adds a random factor to the gossip interval, which is useful to avoid an entire cluster ticking "synchronously"
        /// at the same time, causing spikes in gossip traffic (as all nodes decide to gossip in the same second).
        ///
        /// - example: A random factor of `0.5` results in backoffs between 50% below and 50% above the base interval.
        /// - warning: MUST be between: `<0; 1>` (inclusive)
        public var gossipIntervalRandomFactor: Double = 0.2 {
            willSet {
                precondition(newValue >= 0, "settings.crdt.gossipIntervalRandomFactor MUST BE >= 0, was: \(newValue)")
                precondition(newValue <= 1, "settings.crdt.gossipIntervalRandomFactor MUST BE <= 1, was: \(newValue)")
            }
        }

        public var effectiveGossipInterval: TimeAmount {
            let baseInterval = self.gossipInterval
            let randomizeMultiplier = Double.random(in: (1 - self.gossipIntervalRandomFactor) ... (1 + self.gossipIntervalRandomFactor))
            let randomizedInterval = baseInterval * randomizeMultiplier
            return randomizedInterval
        }

        public var peerDiscovery: PeerDiscovery = .manuallyIntroduced
        public enum PeerDiscovery {
            /// Peers have to be manually introduced by calling `control.introduce()` on to the gossiper.
            /// This gives full control about when a peer should join the gossip group, however usually is not necessary
            /// as one can normally rely on the cluster events (e.g. a member becoming `.up`) to join the group which is
            case manuallyIntroduced

            /// Automatically register this gossiper and subscribe for any others identifying under the same
            /// `Receptionist.RegistrationKey<GossipShell<Gossip, Acknowledgement>.Message>(id)`.
            case fromReceptionistListing(id: String)

            /// Automatically discover and add cluster members to the gossip group when they become reachable in `atLeast` status.
            ///
            /// Note that by default `.leaving`, `.down` and `.removed` members are NOT added to the gossip group,
            /// even if they were never contacted by this gossiper before.
            case onClusterMember(atLeast: Cluster.MemberStatus, resolve: (Cluster.Member) -> AddressableActorRef)
        }
    }
}
