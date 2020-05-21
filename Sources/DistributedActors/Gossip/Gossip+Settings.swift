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

extension GossipShell {
    public struct Settings {
        /// Interval at which gossip rounds should proceed.
        public var gossipInterval: TimeAmount = .seconds(1)

        public var peerDiscovery: PeerDiscovery = .manuallyIntroduced
        public enum PeerDiscovery {
            /// Automatically register this gossiper and subscribe for any others identifying under the same
            /// `Receptionist.RegistrationKey<GossipShell<Metadata, Payload>.Message>(id)`.
            case fromReceptionistListing(id: String)

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
    }
}
