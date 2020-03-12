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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Actor

extension Actor {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.address)
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let address = try container.decode(ActorAddress.self)

        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingActorSerializationContext(ActorRef<Message>.self, details: "While decoding [\(address)], using [\(decoder)]")
        }

        self = .init(ref: context.resolveActorRef(identifiedBy: address))
    }
}
