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

@testable import DistributedActors
import DistributedActorsTestTools
import XCTest

class BackoffStrategyTests: XCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Constant backoff

    func test_constantBackoff_shouldAlwaysYieldSameTimeAmount() {
        let backoff = Backoff.constant(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(100))
    }

    func test_constantBackoff_reset_shouldDoNothing() {
        let backoff = Backoff.constant(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.reset()
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.reset()
        backoff.next()?.shouldEqual(.milliseconds(100))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Exponential backoff

    func test_exponentialBackoff_shouldIncreaseBackoffEachTime() {
        var backoff = Backoff.exponential(initialInterval: .milliseconds(100))
        let b1: TimeAmount = backoff.next()!
        b1.shouldBeGreaterThanOrEqual(TimeAmount.milliseconds(75))
        b1.shouldBeLessThanOrEqual(TimeAmount.milliseconds(130))

        let b2: TimeAmount = backoff.next()!
        b2.shouldBeGreaterThanOrEqual(TimeAmount.milliseconds(100))
        b2.shouldBeLessThanOrEqual(TimeAmount.milliseconds(260))
    }

    func test_exponentialBackoff_shouldAllowDisablingRandomFactor() {
        var backoff = Backoff.exponential(initialInterval: .milliseconds(100), randomFactor: 0)
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(150))

        backoff.next()?.shouldEqual(.nanoseconds(225_000_000))

        backoff.next()?.shouldEqual(.nanoseconds(337_500_000))
    }

    func test_exponentialBackoff_reset_shouldResetBackoffIntervals() {
        var backoff = Backoff.exponential(initialInterval: .milliseconds(100), randomFactor: 0)
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(150))
        backoff.reset()
        backoff.next()?.shouldEqual(.milliseconds(100))
        backoff.next()?.shouldEqual(.milliseconds(150))
    }

    func test_exponentialBackoff_shouldNotExceedMaximumBackoff() {
        let max = TimeAmount.seconds(1)
        let maxRandomNoise = max * 1.25
        var backoff = Backoff.exponential(initialInterval: .milliseconds(500), maxInterval: max)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
    }
}
