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
import DistributedActorsConcurrencyHelpers
import NIO

struct BallotNumber: Codable, Comparable {
    var counter: UInt64
    var id: String

    init(counter: UInt64, id: String) {
        self.counter = counter
        self.id = id
    }

    public static var zero: BallotNumber {
        .init(counter: 0, id: "")
    }

    mutating func increment() {
        self.counter += 1
    }

    func next() -> Self {
        Self(counter: self.counter + 1, id: self.id)
    }

    mutating func fastForward(after tick: BallotNumber) {
        self.counter = max(self.counter, tick.counter) + 1
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        // TODO: [2.1] To compare ballot tuples, we should compare the first component of the tuples and use ID only as a tiebreaker

        lhs.counter < rhs.counter
    }
}
