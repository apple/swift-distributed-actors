//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Swift Distributed ActorsActor

extension Philosopher.Message {

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()

        switch try container.decode(String.self) {
        case "think":
            self = .think
        case "eat":
            self = .eat
        case "forkReply":
            let reply = try container.decode(Fork.Replies.self)
            self = .forkReply(reply)
        case let unknown:
            throw PhilosophersCodingError("Unexpected philosopher message type: \(unknown)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        switch self {
        case .think:
            try container.encode("think")
        case .eat:
            try container.encode("eat")
        case .forkReply(let reply):
            try container.encode("forkReply")
            try container.encode(reply)
        }
    }
}

extension Fork.Messages {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()

        switch try container.decode(String.self) {
        case "putBack":
            let ref = try container.decode(Philosopher.Ref.self)
            self = .putBack(by: ref)
        case "take": 
//            let ref = try container.decode(ActorRef<Fork.Replies>.self)
//            self = .take(by: ref)
            let ref = try container.decode(Philosopher.Ref.self)
            self = .take(by: ref)
        case let unknown:
            throw PhilosophersCodingError("Unexpected fork message type: \(unknown)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        switch self {
        case .putBack(let philosopher):
            try container.encode("putBack")
            try container.encode(philosopher)
        case .take(let philosopher):
            try container.encode("take")
            try container.encode(philosopher)
        }
    }
}

extension Fork.Replies {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(String.self) {
        case "busy":
            let ref = try container.decode(Fork.Ref.self)
            self = .busy(fork: ref)
        case "pickedUp":
            let ref = try container.decode(Fork.Ref.self)
            self = .pickedUp(fork: ref)
        case let unknown:
            throw PhilosophersCodingError("Unexpected fork message type: \(unknown)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .busy(let fork):
            try container.encode("busy")
            try container.encode(fork)
        case .pickedUp(let fork):
            try container.encode("pickedUp")
            try container.encode(fork)
        }
    }
}

struct PhilosophersCodingError: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}
