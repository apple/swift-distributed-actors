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
    final class GossipReplicatorLogic: GossipLogicProtocol {
        typealias Metadata = Void // last metadata we have from the other peer?
        typealias Payload = CRDT.Gossip

        // v1) [node: state sent], te to gossip to everyone
        // v2) [node: [metadata = version vector, and compare if the target knows it already or not]]]
        // v3) [node: pending deltas to deliver]
        // ...
        /// The latest, most up-to-date, version of the gossip that will be spread when a gossip round happens.
        private var latest: CRDT.Gossip?

//        let peerSelector: PeerSelection = fatalError()

        init() {
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Spreading gossip

        func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
            peers // always gossip to everyone
        }

        func makePayload(target _: AddressableActorRef) -> Payload? {
            // v1, everyone gets the entire CRDT state, no optimizations
            self.latest
        }

        // TODO: back channel to eventually stop gossiping the value

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Receiving gossip

        func receiveGossip(payload: Payload) {
        // TODO; some context would be nice, I want to log here
            pprint("Received gossip = \(payload)")
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Side-channel to Direct-replicator

        func subReceive(any: Any) {
            // receive ACKs from direct replicator
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
        let payload: StateBasedCRDT

        init(payload: StateBasedCRDT) {
            self.payload = payload
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