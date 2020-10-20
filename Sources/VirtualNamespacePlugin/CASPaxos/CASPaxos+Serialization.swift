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

extension CASPaxos.Message {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let message = try container.decode(CASPaxos<Value>.Acceptor.Message.self)
        self = .acceptorMessage(message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .local:
            fatalError(".local message must not be sent over the wire, was: \(self)")

        case .acceptorMessage(let message):
            try container.encode(message)
        }
    }
}
