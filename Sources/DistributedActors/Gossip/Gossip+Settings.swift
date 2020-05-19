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

protocol GossipEnvelopeProtocol {
    associatedtype Metadata
    associatedtype Payload: Codable

    // Payload MAY contain the metadata, and we just expose it, or metadata is separate and we do NOT gossip it.

    var metadata: Metadata { get }
    var payload: Payload { get }
}

protocol GossipClient {
    associatedtype Metadata
    associatedtype Payload: Codable

    /// Invoked whenever an incoming gossip is received.
    func receiveGossip(incoming gossip: Payload, existing: GossipEnvelope<Metadata, Payload>?) -> GossipReceivedDirective<Metadata, Payload>

    /// Return `nil` to instruct the infrastructure to stop gossiping this specific payload.
    func onGossipRound(identity: GossipIdentifier, prepared: GossipEnvelope<Metadata, Payload>) -> GossipRoundDirective<Metadata, Payload>

//    func afterGossipRound(identity: GossipIdentity, prepared: GossipEnvelope<Metadata, Payload>) ->

//    var peerSelection: PeerSelection { get }
}

struct GossipClientBox<Metadata, Payload: Codable> {}

// TODO: would LOVE to nest enums in protocols
enum GossipReceivedDirective<Metadata, Payload: Codable> {
    case update(Metadata?, Payload?) // TODO: but async
}

enum GossipRoundDirective<Metadata, Payload: Codable> {
    case gossip(GossipEnvelope<Metadata, Payload>)
    case remove
}

extension GossipShell {
    public struct Settings {
        /// Interval at which gossip rounds should proceed.
        public var gossipInterval: TimeAmount = .seconds(1)

        // var delegate: GossipClientBox<Metadata, Payload> // TODO: express as delegate
//
        ////        /// The "user" of this gossip instance, we notify it whenever we receive a new gossip message.
        ////        private let notifyOnGossipRef: ActorRef<Payload>
//        var onGossipReceived: (GossipIdentifier, Payload, GossipEnvelope<Metadata, Payload>?) -> Void = { _, _, _ in
//            ()
//        }
//
//        /// Invoked during each gossip "round" right before a payload is to be gossiped to peers.
//        ///
//        /// The returned value will be used as the gossip round's payload, and stored for future gossip rounds.
//        /// This allows the system to modify the payload each time (e.g. to (inc-)decrement a counter in the metadata,
//        /// or gossip only a sub-set of the data.
//        ///
//        /// Returning `nil` results in the
//        /// // TODO rather we should return a directive here? .lastGossip(), .gossip(), .remove() etc?
//        /// // TODO we need different Storage and Payload and a Storage -> Payload I guess as we do not want to send the "send 3 more times" information
//        var onGossipRound: (GossipIdentifier, GossipEnvelope<Metadata, Payload>) -> GossipEnvelope<Metadata, Payload> = { _, envelope in
//            envelope
//        }
//
//        // TODO: slight jitter to the gossip rounds?

        /// Configure how peers should be discovered and added to the gossip group.
        ///
        /// By default, the gossiper does not know how to locate its peers, and a key can be passed in to make it
        /// use the `Receptionist` to (register itself and) locate its peers.
        ///
        /// Peers may be added manually by sending the `introduce` message at any time, the gossiper will NOT reject such
        /// introduced peer, even if operating in an auto-discovery mode (may be useful to inject a test listener probe into the gossip group).
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

        // TODO: configurable who to gossip to
        /// var gossipTargetSelection: PeerSelection = .random
    }
}
