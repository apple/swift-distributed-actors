//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import DistributedActors

distributed actor Fork {
    private let name: String
    private var isTaken: Bool = false

    init(name: String, transport: ActorTransport) {
        self.name = name
    }

    distributed func take() -> Bool {
        if self.isTaken {
            return false
        }

        self.isTaken = true
        return true
    }

    distributed func putBack() {
        precondition(self.isTaken, "Attempted to put back a fork that is not taken!")
        self.isTaken = false
    }
}
