//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossiper Settings

extension Gossiper {
    struct Settings {
        /// Interval at which gossip rounds should proceed.
        ///
        /// - SeeAlso: `intervalRandomFactor`
        var interval: Duration

        /// Adds a random factor to the gossip interval, which is useful to avoid an entire cluster ticking "synchronously"
        /// at the same time, causing spikes in gossip traffic (as all nodes decide to gossip in the same second).
        ///
        /// - example: A random factor of `0.5` results in backoffs between 50% below and 50% above the base interval.
        /// - warning: MUST be between: `<0; 1>` (inclusive)
        var intervalRandomFactor: Double = 0.2 {
            willSet {
                precondition(newValue >= 0, "intervalRandomFactor MUST BE >= 0, was: \(newValue)")
                precondition(newValue <= 1, "intervalRandomFactor MUST BE <= 1, was: \(newValue)")
            }
        }

        var effectiveInterval: Duration {
            let baseInterval = self.interval
            let randomizeMultiplier = Double.random(in: (1 - self.intervalRandomFactor) ... (1 + self.intervalRandomFactor))
            let randomizedInterval = baseInterval * randomizeMultiplier
            return randomizedInterval
        }

        /// Hints the Gossiper at weather or not acknowledgments are expected or not.
        ///
        /// If a gossiper which does not expect acknowledgements would be about to send an ack, a warning will be logged.
        var style: GossipSpreadingStyle
        enum GossipSpreadingStyle {
            /// Gossip does NOT require acknowledgements and messages will be spread using uni-directional `tell` message sends.
            case unidirectional

            /// Gossip DOES expect acknowledgements for spread messages, and messages will be spread using `ask` message sends.
            case acknowledged(timeout: Duration)
        }

        /// How the gossiper should discover peers to gossip with.
        var peerDiscovery: PeerDiscovery = .manuallyIntroduced
        enum PeerDiscovery {
            /// Peers have to be manually introduced by calling `control.introduce()` on to the gossiper.
            /// This gives full control about when a peer should join the gossip group, however usually is not necessary
            /// as one can normally rely on the cluster events (e.g. a member becoming `.up`) to join the group which is
            case manuallyIntroduced

            /// Automatically register this gossiper and subscribe for any others identifying under the same
            /// `_Reception.Key<GossipShell<Gossip, Acknowledgement>.Message>(id)`.
            case fromReceptionistListing(id: String)

            /// Automatically discover and add cluster members to the gossip group when they become reachable in `atLeast` status.
            ///
            /// Note that by default `.leaving`, `.down` and `.removed` members are NOT added to the gossip group,
            /// even if they were never contacted by this gossiper before.
            case onClusterMember(atLeast: Cluster.MemberStatus, resolve: (Cluster.Member) -> _AddressableActorRef)
        }
    }
}
