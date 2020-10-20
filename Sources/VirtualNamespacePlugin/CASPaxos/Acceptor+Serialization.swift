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

import DistributedActors
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Acceptor.Message

extension CASPaxos.Acceptor.Message {
    enum DiscriminatorKeys: String, Codable {
        case prepare
        case accept
    }

    enum CodingKeys: CodingKey {
        case _case
        case key
        case ballot
        case state
        case promise
        case replyTo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .prepare:
            let key = try container.decode(String.self, forKey: .key)
            let ballot = try container.decode(BallotNumber.self, forKey: .ballot)
            let replyTo = try container.decode(ActorRef<CASPaxos<Value>.Acceptor.Preparation>.self, forKey: .replyTo)
            self = .prepare(key: key, ballot: ballot, replyTo: replyTo)

        case .accept:
            let key = try container.decode(String.self, forKey: .key)
            let ballot = try container.decode(BallotNumber.self, forKey: .ballot)
            let state = try container.decode(Value.self, forKey: .state)
            let promise = try container.decode(BallotNumber.self, forKey: .promise)
            let replyTo = try container.decode(ActorRef<CASPaxos<Value>.Acceptor.Acceptance>.self, forKey: .replyTo)
            self = .accept(key: key, ballot: ballot, value: state, promise: promise, replyTo: replyTo)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prepare(let key, let ballot, let replyTo):
            try container.encode(DiscriminatorKeys.prepare, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(ballot, forKey: .ballot)
            try container.encode(replyTo, forKey: .replyTo)

        case .accept(let key, let ballot, let state, let promise, let replyTo):
            try container.encode(DiscriminatorKeys.accept, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(ballot, forKey: .ballot)
            try container.encode(state, forKey: .state)
            try container.encode(promise, forKey: .promise)
            try container.encode(replyTo, forKey: .replyTo)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Acceptor.Preparation

extension CASPaxos.Acceptor.Preparation {
    enum DiscriminatorKeys: String, Codable {
        case conflict
        case prepared
    }

    enum CodingKeys: CodingKey {
        case _case
        case ballot
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .conflict:
            let ballot = try container.decode(BallotNumber.self, forKey: .ballot)
            self = .conflict(ballot: ballot)

        case .prepared:
            let ballot = try container.decode(BallotNumber.self, forKey: .ballot)
            let value = try container.decode(Value?.self, forKey: .value)
            self = .prepared(ballot: ballot, value: value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conflict(let ballot):
            try container.encode(DiscriminatorKeys.conflict, forKey: ._case)
            try container.encode(ballot, forKey: .ballot)

        case .prepared(let ballot, let value):
            try container.encode(DiscriminatorKeys.prepared, forKey: ._case)
            try container.encode(ballot, forKey: .ballot)
            try container.encode(value, forKey: .value)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Acceptor.Acceptance

extension CASPaxos.Acceptor.Acceptance {
    enum DiscriminatorKeys: String, Codable {
        case conflict
        case ok
    }

    enum CodingKeys: CodingKey {
        case _case
        case ballot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .conflict:
            let ballot = try container.decode(BallotNumber.self, forKey: .ballot)
            self = .conflict(ballot: ballot)

        case .ok:
            self = .ok
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conflict(let ballot):
            try container.encode(DiscriminatorKeys.conflict, forKey: ._case)
            try container.encode(ballot, forKey: .ballot)

        case .ok:
            try container.encode(DiscriminatorKeys.ok, forKey: ._case)
        }
    }
}
