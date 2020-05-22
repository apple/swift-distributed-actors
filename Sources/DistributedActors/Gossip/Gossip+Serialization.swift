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

import struct Foundation.Data

extension GossipShell.Message: Codable {
    public enum DiscriminatorKeys: String, Codable {
        case gossip
    }

    public enum CodingKeys: CodingKey {
        case _case
        case gossip_identifier
        case gossip_identifier_manifest
        case origin
        case gossip_payload
        case gossip_payload_manifest
    }

    public init(from decoder: Decoder) throws {
        guard let context: Serialization.Context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .gossip:

            let identifierManifest = try container.decode(Serialization.Manifest.self, forKey: .gossip_identifier_manifest)
            let identifierPayload = try container.decode(Data.self, forKey: .gossip_identifier)
            let identifierAny = try context.serialization.deserializeAny(from: .data(identifierPayload), using: identifierManifest)
            guard let identifier = identifierAny as? GossipIdentifier else { // FIXME: just force GossipIdentifier to be codable, avoid this hacky dance?
                fatalError("Cannot cast to GossipIdentifier, was: \(identifierAny)")
            }

            let originAddress = try container.decode(ActorAddress.self, forKey: .origin)
            let origin = context.resolveActorRef(Self.self, identifiedBy: originAddress)

            // FIXME: sometimes we could encode raw and not via the Data -- think about it and fix it
            let payloadManifest = try container.decode(Serialization.Manifest.self, forKey: .gossip_payload_manifest)
            let payloadPayload = try container.decode(Data.self, forKey: .gossip_payload)
            let payload = try context.serialization.deserialize(as: Envelope.self, from: .data(payloadPayload), using: payloadManifest)

            self = .gossip(identity: identifier, origin: origin, payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard let context: Serialization.Context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .gossip(let identifier, let origin, let payload):
            try container.encode(DiscriminatorKeys.gossip, forKey: ._case)

            let serializedIdentifier = try context.serialization.serialize(identifier)
            try container.encode(serializedIdentifier.manifest, forKey: .gossip_identifier_manifest)
            try container.encode(serializedIdentifier.buffer.readData(), forKey: .gossip_identifier)

            try container.encode(origin.address, forKey: .origin)

            let serializedPayload = try context.serialization.serialize(payload)
            try container.encode(serializedPayload.manifest, forKey: .gossip_payload_manifest)
            try container.encode(serializedPayload.buffer.readData(), forKey: .gossip_payload)

        default:
            throw SerializationError.unableToSerialize(hint: "\(reflecting: Self.self)")
        }
    }
}
