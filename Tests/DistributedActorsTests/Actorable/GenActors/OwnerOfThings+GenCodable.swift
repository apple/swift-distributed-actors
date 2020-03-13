// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

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

import DistributedActors
import class NIO.EventLoopFuture

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Codable conformance for OwnerOfThings.Message
// TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values 

extension OwnerOfThings.Message {
    // TODO: Check with Swift team which style of discriminator to aim for
    public enum DiscriminatorKeys: String, Decodable {
        case readLastObservedValue
        case performLookup
        case performSubscribe

    }

    public enum CodingKeys: CodingKey {
        case _case
        case readLastObservedValue__replyTo
        case performLookup__replyTo
        case performSubscribe_p

    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .readLastObservedValue:
            let _replyTo = try container.decode(ActorRef<Reception.Listing<OwnerOfThings>?>.self, forKey: CodingKeys.readLastObservedValue__replyTo)
            self = .readLastObservedValue(_replyTo: _replyTo)
        case .performLookup:
            let _replyTo = try container.decode(ActorRef<Result<Reception.Listing<OwnerOfThings>, Error>>.self, forKey: CodingKeys.performLookup__replyTo)
            self = .performLookup(_replyTo: _replyTo)
        case .performSubscribe:
            let p = try container.decode(ActorRef<Reception.Listing<OwnerOfThings>>.self, forKey: CodingKeys.performSubscribe_p)
            self = .performSubscribe(p: p)

        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .readLastObservedValue(let _replyTo):
            try container.encode(DiscriminatorKeys.readLastObservedValue.rawValue, forKey: CodingKeys._case)
            try container.encode(_replyTo, forKey: CodingKeys.readLastObservedValue__replyTo)
        case .performLookup(let _replyTo):
            try container.encode(DiscriminatorKeys.performLookup.rawValue, forKey: CodingKeys._case)
            try container.encode(_replyTo, forKey: CodingKeys.performLookup__replyTo)
        case .performSubscribe(let p):
            try container.encode(DiscriminatorKeys.performSubscribe.rawValue, forKey: CodingKeys._case)
            try container.encode(p, forKey: CodingKeys.performSubscribe_p)

        }
    }
}
