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

// TODO: parameterized extensions would help here
extension ActorRef {

    // TODO: nicer signature, i.e. throw the Error and flatten the result
    func change<Value>(key: String, timeout: DistributedActors.TimeAmount, change: @escaping CASPaxos<Value>.ChangeFunction) -> AskResponse<Value?>
        where Value: Codable, Message == CASPaxos<Value>.Message {
        self.ask(timeout: timeout) {
            CASPaxos<Value>.Message.local(.change(key: key, change: change, replyTo: $0))
        }
    }

    /// Set an initial value, i.e. only set it if it was not set before
    func initialize<Value>(key: String, initialValue: Value, timeout: DistributedActors.TimeAmount) -> AskResponse<Value?>
        where Value: Codable, Message == CASPaxos<Value>.Message {
        self.change(key: key, timeout: timeout, change: {
            switch $0 {
            case nil: return initialValue
            case .some(let existingValue): return existingValue
            }
        })
    }

    func read<Value>(key: String, timeout: DistributedActors.TimeAmount) -> AskResponse<Value?>
        where Value: Codable, Message == CASPaxos<Value>.Message {
        self.change(key: key, timeout: timeout, change: { $0 })
    }
}
