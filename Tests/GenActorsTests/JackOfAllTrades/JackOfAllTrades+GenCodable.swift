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
// MARK: DO NOT EDIT: Codable conformance for JackOfAllTrades.Message
// TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values

extension JackOfAllTrades.Message: Codable {
    // TODO: Check with Swift team which style of discriminator to aim for
    public enum DiscriminatorKeys: String, Decodable {
        case hello
        case _boxTicketing
        case _boxParking
    }

    public enum CodingKeys: CodingKey {
        case _case
        case hello_replyTo
        case _boxTicketing
        case _boxParking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .hello:
            let replyTo = try container.decode(ActorRef<String>.self, forKey: CodingKeys.hello_replyTo)
            self = .hello(replyTo: replyTo)
        case ._boxTicketing:
            let boxed = try container.decode(GeneratedActor.Messages.Ticketing.self, forKey: CodingKeys._boxTicketing)
            self = .ticketing(boxed)
        case ._boxParking:
            let boxed = try container.decode(GeneratedActor.Messages.Parking.self, forKey: CodingKeys._boxParking)
            self = .parking(boxed)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let replyTo):
            try container.encode(DiscriminatorKeys.hello.rawValue, forKey: CodingKeys._case)
            try container.encode(replyTo, forKey: CodingKeys.hello_replyTo)
        case .ticketing(let boxed):
            try container.encode(boxed, forKey: CodingKeys._boxTicketing)
        case .parking(let boxed):
            try container.encode(boxed, forKey: CodingKeys._boxParking)
        }
    }
}
