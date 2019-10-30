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

// TODO: take into account that type may not be public
public struct TestActorable: Actorable {
    var messages: [String] = []

    let context: ActorContext<Message>

    public init(context: ActorContext<Message>) {
        self.context = context
    }

    public mutating func ping() {
        self.messages.append("\(#function)")
    }

    public mutating func greet(name: String) {
        self.messages.append("\(#function):\(name)")
    }

    public mutating func greetUnderscoreParam(_ name: String) {
        self.messages.append("\(#function):\(name)")
    }

    public mutating func greet2(name: String, surname: String) {
        self.messages.append("\(#function):\(name),\(surname)")
    }
}
