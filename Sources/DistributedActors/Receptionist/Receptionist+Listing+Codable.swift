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

extension Receptionist.Listing: ActorMessage {
    enum CodingKeys: CodingKey {
        case manifest
        case listing
    }

    public init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Receptionist.Listing<T>.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        let manifest = try container.decode(Serialization.Manifest.self, forKey: .manifest)
        let listingType = try context.summonType(from: manifest)

        guard let anyListingType = listingType as? AnyReceptionistListing.Type else {
            throw SerializationError.unableToDeserialize(hint: "Unknown listing type: \(listingType)")
        }

        let listingDecoder = try container.superDecoder(forKey: .listing)
        self.underlying = try anyListingType.init(from: listingDecoder)
    }

    public func encode(to encoder: Encoder) throws {
        guard let context: Serialization.Context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, Receptionist.Listing<T>.self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context.serialization.outboundManifest(type(of: self.underlying as Any)), forKey: .manifest)

        let listingEncoder = container.superEncoder(forKey: .listing)
        try self.underlying.encode(to: listingEncoder)
    }
}
