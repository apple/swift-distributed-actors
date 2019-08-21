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

import DistributedActors
import DistributedActorsTestKit
import XCTest

final class LamportClockTests: XCTestCase {
    func test_lamportClock_movesOnlyForward() {
        var lClock = LamportClock()
        lClock.time.shouldEqual(0)

        lClock.increment()
        lClock.time.shouldEqual(1)

        lClock.witness(42)
        lClock.time.shouldEqual(42)

        lClock.witness(13)
        lClock.time.shouldEqual(42)

        lClock.increment()
        lClock.time.shouldEqual(43)
    }
}
