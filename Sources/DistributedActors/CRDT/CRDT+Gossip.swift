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
    /// Gossip Replicator logic, it gossips CRDTs (and deltas) to other peers in the cluster.
    ///
    /// It collaborates with the Direct Replicator in order to avoid needlessly sending values to nodes which already know
    /// about them (e.g. through direct replication).
    final class GossipReplicatorLogic: GossipLogic {
        typealias Metadata = Void // last metadata we have from the other peer?
        typealias Envelope = CRDT.Gossip

        let identity: CRDT.Identity
        let context: Context
        let replicatorControl: CRDT.Replicator.Shell.LocalControl

        // TODO: This is a naive impl "v1" better gossip aware impls to follow soon:
        // v1) [node: state sent], te to gossip to everyone
        // v2) [node: [metadata = version vector, and compare if the target knows it already or not]]]
        // v3) [node: pending deltas to deliver] - build a queue of gossips and spread them to others on "per need" bases;
        //     as we receive incoming gossips, we notice at what VV they are, and can know "that node needs to know at-least from V4 vector time deltas"
        // ...
        /// The latest, most up-to-date, version of the gossip that will be spread when a gossip round happens.
        /// TODO: perhaps keep the latest CRDT value instead, as the gossip will be per-peer determined.
        private var latest: CRDT.Gossip?

        // let peerSelector: PeerSelection // TODO: consider moving the existing logic into reusable?
        var alreadyInformedPeers: Set<ActorAddress>

        init(_ context: Context, _ replicatorControl: CRDT.Replicator.Shell.LocalControl) {
            guard let identity = context.gossipIdentifier as? CRDT.Identity else {
                fatalError("\(context.gossipIdentifier) MUST be \(CRDT.Identity.self)")
            }

            self.identity = identity
            self.context = context
            self.replicatorControl = replicatorControl
            self.alreadyInformedPeers = []
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Spreading gossip

        // we gossip only to peers we have not gossiped to yet.
        func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
            guard let xxxx = self.latest else {
                return [] // we have nothing to gossip
            }

            let n = 1
            var selectedPeers : [AddressableActorRef] = []
            selectedPeers.reserveCapacity(n)

            // we randomly pick peers; TODO: can be improved, in SWIM like peer selection (shuffle them once, then go round robin)
            for peer in peers.shuffled() where selectedPeers.count < n {
                if !self.alreadyInformedPeers.contains(peer.address) {
                    selectedPeers.append(peer)
                }
            }

            self.context.log.notice("""
                                    [selectPeers] \(peers)
                                    ALREADY SENT TO: \(pretty: self.alreadyInformedPeers)

                                    SELECTED: \(optional: selectedPeers)

                                    GOSSIP: \(pretty: xxxx)
                                    """)

            return selectedPeers
        }

        func makePayload(target _: AddressableActorRef) -> CRDT.Gossip? {
            // v1, everyone gets the entire CRDT state, no optimizations
            self.latest
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Receiving gossip

        // FIXME: we need another "was updated locally" so we avoid causing an infinite update loop; perhaps use metadata for it -- source of the mutation etc?
        func receiveGossip(origin: AddressableActorRef, payload: CRDT.Gossip) {
            self.mergeInbound(from: origin, payload)
            self.replicatorControl.tellGossipWrite(id: self.identity, data: payload.payload)
        }

        func localGossipUpdate(payload: CRDT.Gossip) {
            self.mergeInbound(from: payload.metadata.origin, payload)
            // during the next gossip round we'll gossip the latest most-up-to date version now;
            // no need to schedule that, we'll be called when it's time.
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Side-channel to Direct-replicator

        // TODO: It is likely that direct replicator will end up NOT storing any data and we use the gossip one as the storage
        // this would change around interactions a bit; note that today we keep the CRDT in both places, in the direct replicator
        // and gossip replicator, so that's a downside that we'll eventually want to address.

        enum SideChannelMessage {
            case localUpdate(CRDT.Gossip)
        }

        func receiveSideChannelMessage(message: Any) throws {
            guard let sideChannelMessage = message as? SideChannelMessage else {
                return // TODO: dead letter it
            }

            // TODO: receive ACKs from direct replicator
            switch sideChannelMessage {
            case .localUpdate(let payload):
                self.mergeInbound(from: nil, payload)
                self.alreadyInformedPeers = [] // local update means we definitely need to share it with others
            }
        }

        private func mergeInbound(from peer: AddressableActorRef?, _ payload: CRDT.Gossip) {
            self.context.log.notice("""
                                    [mergeInbound] INCOMING.....
                                    INCOMING: \(pretty: payload)
                                    CURRENT: \(optional: self.latest)
                                    """)

            // TODO: some context would be nice, I want to log here
            // TODO: metadata? who did send us this payload?
            guard var latest = self.latest else {
                self.latest = payload // we didn't have one stored, so direcly apply
                self.alreadyInformedPeers = []
                return
            }

            self.context.log.notice("""
                                    [mergeInbound] 
                                    CURRENT: \(pretty: latest)
                                    """)

            let latestBeforeMerge = latest // CRDTs have value semantics
            if let error = latest.tryMerge(other: payload.payload) {
                _ = error // FIXME: log the error
            }

            self.latest = latest

            guard latestBeforeMerge.payload.equalState(to: latest.payload) else {
                self.context.log.notice("""
                       [mergeInbound] DIFF THAN LOCAL; RESET SENDS
                           latestBeforeMerge = \(pretty: latestBeforeMerge) 
                           latest= \(pretty: latest)
                       """)
                // The incoming gossip caused ours to change; this information was potentially not yet spread to other nodes
                // thus we reset our set of who already khows about "our" (most recent observed by this node) state of the CRDT.
                //
                // TODO: This is a naive implementation and leads to much more gossip than necessary with delta tracking.
                // In delta tracking, we'd add to the queue that the delta, and keep track which nodes know about which part of the state
                // and if they need to see this delta or not. We'd then only gossip to them; and once we've seen everyone "seen"
                // this delta, we drop it from our send queue. This is "v3" version we want to get to.
                self.alreadyInformedPeers = []
                return
            }

            // it was the same gossip as we store already, no need to gossip it more.
            let b = self.alreadyInformedPeers
            if let p = peer {
                self.alreadyInformedPeers.insert(p.address) // FIXME ensure if this is right
            }
            self.context.log.notice("""
                   [mergeInbound] SAME AS LOCAL, INSERT PEER \(optional: peer)
                       latestBeforeMerge = \(pretty: latestBeforeMerge)
                       latest            = \(pretty: latest)
                       self.alreadyInformedPeers BEFORE = \(b)
                       self.alreadyInformedPeers AFTER = \(self.alreadyInformedPeers)
                   """)
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
        struct Metadata: Codable {
            let origin: AddressableActorRef? // FIXME

            var isLocalWrite: Bool {
                self.origin == nil
            }
            var isGossipWrite: Bool {
                !self.isLocalWrite
            }
        }
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
