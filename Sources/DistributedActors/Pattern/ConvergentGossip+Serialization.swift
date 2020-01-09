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

extension ConvergentGossip.Message: Codable {
    public enum DiscriminatorKeys: String, Codable {
        case gossip
    }

    public enum CodingKeys: CodingKey {
        case _case

        case gossip_envelope
    }

    /*
     keyNotFound(
     CodingKeys(stringValue: "_case", intValue: nil),
     Swift.DecodingError.Context(codingPath: [
         CodingKeys(stringValue: "gossip_envelope", intValue: nil),
         CodingKeys(stringValue: "payload", intValue: nil),
         CodingKeys(stringValue: "seen", intValue: nil),
         CodingKeys(stringValue: "table", intValue: nil),
          _JSONKey(stringValue: "Index 1", intValue: 1),
          CodingKeys(stringValue: "state", intValue: nil),
          _JSONKey(stringValue: "Index 0", intValue: 0)
      ],
      debugDescription: "No value associated with key CodingKeys(stringValue: "_case", intValue: nil) ("_case").", underlyingError: nil))

     */

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
            throw SerializationError.mayNeverBeSerialized(type: "\(self)")
        }
    }
}
