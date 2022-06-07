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

extension _Reception.Listing: ActorMessage {
    enum CodingKeys: CodingKey {
        case listing
        case key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.key = try container.decode(_Reception.Key<Guest>.self, forKey: .key)
        let listingDecoder = try container.superDecoder(forKey: .listing)
        self.underlying = try Set<_AddressableActorRef>(from: listingDecoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.key, forKey: .key)

        let listingEncoder = container.superEncoder(forKey: .listing)
        try self.underlying.encode(to: listingEncoder)
    }
}

extension _Reception.Key {
    internal enum CodingKeys: CodingKey {
        case manifest
        case id
    }

    public init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, _Reception.Listing<Guest>.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.decode(String.self, forKey: .id)

        let guestManifest = try container.decode(Serialization.Manifest.self, forKey: .manifest)
        let guestType = try context.summonType(from: guestManifest)
        guard guestType is Guest.Type else {
            throw SerializationError.notAbleToDeserialize(hint: "manifest type results in [\(guestType)] type, which is NOT \(Guest.self)")
        }

        self.init(Guest.self, id: id)
    }

    public func encode(to encoder: Encoder) throws {
        guard let context: Serialization.Context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, _Reception.Listing<Guest>.self)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)

        let manifest = try context.outboundManifest(Guest.self)

        try container.encode(manifest, forKey: .manifest)
        try container.encode(self.id, forKey: .id)
    }
}
