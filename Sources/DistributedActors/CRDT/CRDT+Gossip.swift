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

    final class GossipReplicatorLogic: GossipLogicProtocol {
        typealias Metadata = Void
        typealias Payload = CRDT.Gossip

        // v1) [node: state sent], te to gossip to everyone
        // v2) [node: [metadata = version vector, and compare if the target knows it already or not]]]
        // v3) [node: pending deltas to deliver]

//        let peerSelector: PeerSelection = fatalError()

        func selectPeers(membership: Cluster.Membership) -> [Cluster.Member] {
            fatalError()
        }

        func makePayload() -> Payload {
            fatalError()
        }

        func receiveGossip(identifier: GossipIdentifier, payload: Payload) {
            fatalError()
        }

        func subReceive(any: Any) {
            // receive ACKs from direct replicator
        }
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Identity as GossipIdentifier

extension CRDT.Identity: GossipIdentifier {
    public var gossipIdentifier: Key {
        self.id
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