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
        typealias Payload = CRDT.Gossip

        let identity: CRDT.Identity
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

        init(identifier: GossipIdentifier, _ replicatorControl: CRDT.Replicator.Shell.LocalControl) {
            guard let id = identifier as? CRDT.Identity else {
                fatalError("\(identifier) MUST be \(CRDT.Identity.self)")
            }

            self.identity = id
            self.replicatorControl = replicatorControl
            self.alreadyInformedPeers = []
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Spreading gossip

        // we gossip only to peers we have not gossiped to yet.
        func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
            let n = 1
            var selectedPeers : [AddressableActorRef] = []
            selectedPeers.reserveCapacity(n)

            for peer in peers where selectedPeers.count < n {
                if self.alreadyInformedPeers.insert(peer.address).inserted {
                    selectedPeers.append(peer)
                }
            }

            return selectedPeers
        }

        func makePayload(target _: AddressableActorRef) -> Payload? {
            // v1, everyone gets the entire CRDT state, no optimizations
            self.latest
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Receiving gossip

        // FIXME: we need another "was updated locally" so we avoid causing an infinite update loop; perhaps use metadata for it -- source of the mutation etc?
        func receiveGossip(payload: Payload) {
            self.mergeInbound(payload)
            self.replicatorControl.tellGossipWrite(id: self.identity, data: payload.payload)
        }

        func localGossipUpdate(metadata: Metadata, payload: Payload) {
            self.mergeInbound(payload)
            // during the next gossip round we'll gossip the latest most-up-to date version now;
            // no need to schedule that, we'll be called when it's time.
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Side-channel to Direct-replicator

        enum SideChannelMessage {
            case localUpdate(Payload)
        }

        func receiveSideChannelMessage(message: Any) throws {
            guard let sideChannelMessage = message as? SideChannelMessage else {
                return // TODO: dead letter it
            }

            // TODO: receive ACKs from direct replicator
            switch sideChannelMessage {
            case .localUpdate(let payload):
                self.mergeInbound(payload)
            }
        }

        private func mergeInbound(_ payload: CRDT.GossipReplicatorLogic.Payload) {
            // TODO: some context would be nice, I want to log here
            // TODO: metadata? who did send us this payload?
            guard var latest = self.latest else {
                self.latest = payload // we didn't have one stored, so direcly apply
                self.alreadyInformedPeers = []
                return
            }

            let latestBeforeMerge = latest // CRDTs have value semantics
            if let error = latest.tryMerge(other: payload.payload) {
                _ = error // FIXME: log the error
            }

            pprint("[\(self.identity)] merged inbound === \(payload)")
            self.latest = latest

            guard latestBeforeMerge.payload.equalState(to: latest.payload) else {
                pprint("N    latestBeforeMerge = \(latestBeforeMerge)")
                pprint("N    latest            = \(latest)")
                return
            }

            // it was the same gossip as we store already, no need to gossip it more.
            pprint("    latestBeforeMerge = \(latestBeforeMerge)")
            pprint("    latest            = \(latest)")
            self.alreadyInformedPeers = []
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
    struct Gossip: Codable {
        var payload: StateBasedCRDT

        init(payload: StateBasedCRDT) {
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
        case payload
        case payloadManifest
    }

    init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, CRDT.Gossip.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payloadData = try container.decode(Data.self, forKey: .payload)
        let manifest = try container.decode(Serialization.Manifest.self, forKey: .payloadManifest)

        self.payload = try context.serialization.deserialize(as: StateBasedCRDT.self, from: .data(payloadData), using: manifest)
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        let serialized = try context.serialization.serialize(self.payload)
        try container.encode(serialized.buffer.readData(), forKey: .payload)
        try container.encode(serialized.manifest, forKey: .payloadManifest)
    }
}
