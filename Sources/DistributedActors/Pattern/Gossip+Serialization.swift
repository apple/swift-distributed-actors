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

extension GossipShell.Message: Codable {

    public enum DiscriminatorKeys: String, Codable {
        case gossip
    }

    public enum CodingKeys: CodingKey {
        case _case
        case gossip_identifier
        case gossip_payload
        case gossip_payload_manifest
    }

    public init(from decoder: Decoder) throws {
        guard let serializationContext: ActorSerializationContext = encoder.actorSerializationContext else {
            throw ActorCoding.CodingError.missingActorSerializationContext(MyMessage.self, details: "While encoding [\(self)], using [\(encoder)]")
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .gossip:
            let identifierString = try container.decode(String.self, forKey: .gossip_identifier)
            let identifier = StringGossipIdentifier(stringLiteral: identifierString)

            // let payloadManifest = try container.decode(String.self, forKey: .gossip_payload_manifest)
            serializationContext.box(<#T##value: Any##Any#>, ofKnownType: <#T##Any.Type##Any.Type#>, as: <#T##Box.Type##Box.Type#>)
            let payload: Payload = try container.decode(Payload.self, forKey: .gossip_payload)

            self = .gossip(identity: identifier, payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .gossip(let identifier, let payload):
            try container.encode(DiscriminatorKeys.gossip, forKey: ._case)
            try container.encode(identifier.gossipIdentifier, forKey: .gossip_identifier)
            try container.encode(payload, forKey: .gossip_payload)
            try container.encode(String(reflecting: type(of: payload)), forKey: .gossip_payload_manifest)
        default:
            throw SerializationError.mayNeverBeSerialized(type: "\(self)")
        }
    }
}
