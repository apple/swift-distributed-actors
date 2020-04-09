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

extension ConvergentGossip.Message {
    public enum DiscriminatorKeys: String, Codable {
        case gossip
    }

    public enum CodingKeys: CodingKey {
        case _case

        case gossip_envelope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .gossip:
            self = .gossip(try container.decode(ConvergentGossip<Payload>.GossipEnvelope.self, forKey: .gossip_envelope))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .gossip(let envelope):
            try container.encode(DiscriminatorKeys.gossip, forKey: ._case)
            try container.encode(envelope, forKey: .gossip_envelope)
        default:
            throw SerializationError.nonTransportableMessage(type: "\(self)")
        }
    }
}
