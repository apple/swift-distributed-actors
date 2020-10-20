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

extension CASPaxos.Proposer.Message {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let reply = try container.decode(CASPaxos<Value>.Proposer.AcceptorReply.self)
        self = .acceptorReply(reply)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .local:
            fatalError(".local message must not be sent over the wire, was: \(self)")

        case .acceptorReply(let reply):
            try container.encode(reply)
        }
    }
}

extension CASPaxos.Proposer.AcceptorReply {
    enum DiscriminatorKeys: String, Codable {
        case conflict
        case accept
    }

    enum CodingKeys: CodingKey {
        case _case
        case proposed
        case latest
        case accepted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .conflict:
            let proposed = try container.decode(BallotNumber.self, forKey: .proposed)
            let latest = try container.decode(BallotNumber.self, forKey: .latest)
            self = .conflict(proposed: proposed, latest: latest)

        case .accept:
            let accepted = try container.decode(BallotNumber.self, forKey: .accepted)
            self = .accept(accepted: accepted)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conflict(let proposed, let latest):
            try container.encode(DiscriminatorKeys.conflict, forKey: ._case)
            try container.encode(proposed, forKey: .proposed)
            try container.encode(latest, forKey: .latest)

        case .accept(let accepted):
            try container.encode(DiscriminatorKeys.accept, forKey: ._case)
            try container.encode(accepted, forKey: .accepted)
        }
    }
}
