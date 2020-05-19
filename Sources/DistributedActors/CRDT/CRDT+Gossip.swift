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
        let control: CRDT.Replicator.Shell.LocalControl

        // v1) [node: state sent], te to gossip to everyone
        // v2) [node: [metadata = version vector, and compare if the target knows it already or not]]]
        // v3) [node: pending deltas to deliver]
        // ...
        /// The latest, most up-to-date, version of the gossip that will be spread when a gossip round happens.
        private var latest: CRDT.Gossip?

//        let peerSelector: PeerSelection = fatalError()

        init(identifier: GossipIdentifier, _ control: CRDT.Replicator.Shell.LocalControl) {
            guard let id = identifier as? CRDT.Identity else {
                fatalError("\(identifier) MUST be \(CRDT.Identity.self)")
            }

            self.identity = id
            self.control = control
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

        // FIXME: we need another "was updated locally" so we avoid causing an infinite update loop; perhaps use metadata for it -- source of the mutation etc?
        func receiveGossip(payload: Payload) {
//            pprint("[\(identity)] received gossip ... = \(payload)")
            self.mergeInbound(payload)
            self.control.tellGossipWrite(id: self.identity, data: payload.payload)
        }

        func localGossipUpdate(metadata: Metadata, payload: Payload) {
//            pprint("[\(identity)] local gossip update ... \(metadata) = \(payload)")
            self.mergeInbound(payload)
            // during the next gossip round we'll gossip the latest most-up-to date version now;
            // no need to schedule that, we'll be called when it's time.
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Side-channel to Direct-replicator

        enum SideChannelMessage {
            case localUpdate(Payload)
        }

        func receiveSideChannelMessage(message: Any) {
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
            if var existing = self.latest {
                if let error = existing.tryMerge(other: payload.payload) {
                    _ = error // TODO: log the error
                }
                self.latest = existing
            } else {
                self.latest = payload
            }
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
