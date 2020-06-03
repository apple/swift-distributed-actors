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

import struct Foundation.Data

extension CRDT {
    /// Gossip Replicator logic, it gossips CRDTs (and deltas NOT IMPLEMENTED YET) to other peers in the cluster.
    ///
    /// It collaborates with the Direct Replicator in order to avoid needlessly sending values to nodes which already know
    /// about them (e.g. through direct replication).
    final class GossipReplicatorLogic: GossipLogic {
        typealias Envelope = CRDT.Gossip

        let identity: CRDT.Identity
        let context: Context
        let replicatorControl: CRDT.Replicator.Shell.LocalControl

        // TODO: This is a naive impl "v1" better gossip aware impls to follow soon:
        // v1) [node: state sent], te to gossip to everyone
        // ~~v2) [node: [metadata = version vector, and compare if the target knows it already or not]]]~~
        //   (might want to jump right away to v3, it's not much harder but the "right thing" we want to end up with anyway)
        // v3) [node: pending deltas to deliver] - build a queue of gossips and spread them to others on "per need" bases;
        //     as we receive incoming gossips, we notice at what VV they are, and can know "that node needs to know at-least from V4 vector time deltas"
        // ...
        /// The latest, most up-to-date, version of the gossip that will be spread when a gossip round happens.
        // TODO: perhaps keep the latest CRDT value instead, as the gossip will be per-peer determined.
        private var latest: CRDT.Gossip?

        // let peerSelector: PeerSelection // TODO: consider moving the existing logic into reusable?
        var peersAckedOurLatestGossip: Set<ActorAddress>

        init(_ context: Context, _ replicatorControl: CRDT.Replicator.Shell.LocalControl) {
            guard let identity = context.gossipIdentifier as? CRDT.Identity else {
                fatalError("\(context.gossipIdentifier) MUST be \(CRDT.Identity.self)")
            }

            self.identity = identity
            self.context = context
            self.replicatorControl = replicatorControl
            self.peersAckedOurLatestGossip = []
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Spreading gossip

        func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
            // how many peers we select in each gossip round,
            // we could for example be dynamic and notice if we have 10+ nodes, we pick 2 members to speed up the dissemination etc.
            let n = 1

            var selectedPeers: [AddressableActorRef] = []
            selectedPeers.reserveCapacity(n)

            // we randomly pick peers; TODO: can be improved, in SWIM like peer selection (shuffle them once, then go round robin)
            for peer in peers.shuffled() where selectedPeers.count < n {
                if !self.peersAckedOurLatestGossip.contains(peer.address) {
                    selectedPeers.append(peer)
                }
            }

            return selectedPeers
        }

        func makePayload(target _: AddressableActorRef) -> CRDT.Gossip? {
            // v1, everyone gets the entire CRDT state, no optimizations
            // TODO: v3, here we'll want to filter the data we want to send to the target based on what data we already know it has seen
            // e.g. if we know target has definitely seen A@3,B@4, and our state has A@3,B@6, we only need to send delta(B@5, B@6)
            self.latest
        }

        func receivePayloadACK(target: AddressableActorRef, confirmedDeliveryOf envelope: CRDT.Gossip) {
            guard (self.latest.map { $0.payload.equalState(to: envelope.payload) } ?? false) else {
                // received an ack for something, however it's not the "latest" anymore, so we need to gossip to target anyway
                return
            }

            // TODO: in v3 this would translate to ACKing specific deltas for this target
            // good, the latest gossip is still the same as was confirmed here, so we can mark it acked
            self.peersAckedOurLatestGossip.insert(target.address)
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Receiving gossip

        func receiveGossip(origin: AddressableActorRef, payload: CRDT.Gossip) {
            // merge the datatype locally, and update our information about the origin's knowledge about this datatype
            // (does it already know about our data/all-deltas-we-are-aware-of or not)
            self.mergeInbound(from: origin, payload)

            // notify the direct replicator to update all local `actorOwned` CRDTs.
            // TODO: the direct replicator may choose to delay flushing this information a bit to avoid much data churn see `settings.crdt.`
            self.replicatorControl.tellGossipWrite(id: self.identity, data: payload.payload)
        }

        func localGossipUpdate(payload: CRDT.Gossip) {
            self.mergeInbound(from: nil, payload)
            // during the next gossip round we'll gossip the latest most-up-to date version now;
            // no need to schedule that, we'll be called when it's time.
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Side-channel to Direct-replicator

        // TODO: It is likely that direct replicator will end up NOT storing any data and we use the gossip one as the storage
        // this would change around interactions a bit; note that today we keep the CRDT in both places, in the direct replicator
        // and gossip replicator, so that's a downside that we'll eventually want to address.

        enum SideChannelMessage {
            case localUpdate(Envelope)
            case ack(origin: AddressableActorRef, payload: Envelope)
        }

        func receiveSideChannelMessage(message: Any) throws {
            guard let sideChannelMessage = message as? SideChannelMessage else {
                self.context.system.deadLetters.tell(DeadLetter(message, recipient: self.context.gossiperAddress))
                return
            }

            // TODO: receive ACKs from direct replicator
            switch sideChannelMessage {
            case .localUpdate(let payload):
                self.mergeInbound(from: nil, payload)
                self.peersAckedOurLatestGossip = [] // local update means we definitely need to share it with others
            case .ack(let origin, let ackedGossip):
                if let latest = self.latest,
                    latest.payload.equalState(to: ackedGossip.payload) {
                    self.peersAckedOurLatestGossip.insert(origin.address)
                }
            }
        }

        private func mergeInbound(from peer: AddressableActorRef?, _ incoming: CRDT.Gossip) {
            guard var current = self.latest else {
                self.latest = incoming // we didn't have one stored, so directly apply
                self.peersAckedOurLatestGossip = []
                return
            }

            if let error = current.tryMerge(other: incoming.payload) {
                context.log.warning("Failed incoming CRDT gossip, error: \(error)", metadata: [
                    "crdt/incoming": "\(incoming)",
                    "crdt/current": "\(current)",
                ])
            }

            self.latest = current
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Identity as GossipIdentifier

extension CRDT.Identity: GossipIdentifier {
    public var gossipIdentifier: String {
        self.id
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        AnyGossipIdentifier(self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT Gossip envelope

extension CRDT {
    /// The gossip to be spread about a specific CRDT (identity).
    struct Gossip: GossipEnvelopeProtocol, CustomPrettyStringConvertible {
        struct Metadata: Codable {}

        typealias Payload = StateBasedCRDT

        var metadata: Metadata
        var payload: Payload

        init(metadata: CRDT.Gossip.Metadata, payload: CRDT.Gossip.Payload) {
            self.metadata = metadata
            self.payload = payload
        }

        mutating func tryMerge(other: CRDT.Gossip) -> CRDT.MergeError? {
            self.tryMerge(other: other.payload)
        }

        mutating func tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            self.payload._tryMerge(other: other)
        }
    }
}

extension CRDT.Gossip {
    enum CodingKeys: CodingKey {
        case metadata
        case metadataManifest
        case payload
        case payloadManifest
    }

    init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, CRDT.Gossip.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        let manifestData = try container.decode(Data.self, forKey: .metadata)
        let manifestManifest = try container.decode(Serialization.Manifest.self, forKey: .metadataManifest)
        self.metadata = try context.serialization.deserialize(as: Metadata.self, from: .data(manifestData), using: manifestManifest)

        let payloadData = try container.decode(Data.self, forKey: .payload)
        let payloadManifest = try container.decode(Serialization.Manifest.self, forKey: .payloadManifest)
        self.payload = try context.serialization.deserialize(as: StateBasedCRDT.self, from: .data(payloadData), using: payloadManifest)
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        let serializedPayload = try context.serialization.serialize(self.payload)
        try container.encode(serializedPayload.buffer.readData(), forKey: .payload)
        try container.encode(serializedPayload.manifest, forKey: .payloadManifest)

        let serializedMetadata = try context.serialization.serialize(self.metadata)
        try container.encode(serializedMetadata.buffer.readData(), forKey: .metadata)
        try container.encode(serializedMetadata.manifest, forKey: .metadataManifest)
    }
}
