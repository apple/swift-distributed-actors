//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import XCTest

@testable import DistributedCluster

class BackoffStrategyTests: XCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Constant backoff

    func test_constantBackoff_shouldAlwaysYieldSameDuration() {
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
        let b1: Duration = backoff.next()!
        b1.shouldBeGreaterThanOrEqual(Duration.milliseconds(75))
        b1.shouldBeLessThanOrEqual(Duration.milliseconds(130))

        let b2: Duration = backoff.next()!
        b2.shouldBeGreaterThanOrEqual(Duration.milliseconds(100))
        b2.shouldBeLessThanOrEqual(Duration.milliseconds(260))
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
        let max = Duration.seconds(1)
        let maxRandomNoise = max * 1.25
        var backoff = Backoff.exponential(initialInterval: .milliseconds(500), capInterval: max)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
        backoff.next()?.shouldBeLessThanOrEqual(max + maxRandomNoise)
    }

    func test_exponentialBackoff_shouldStopAfterMaxAttempts() {
        let maxAttempts = 3
        var backoff = Backoff.exponential(
            initialInterval: .milliseconds(500),
            randomFactor: 0,
            maxAttempts: maxAttempts
        )
        backoff.next()!.shouldEqual(.milliseconds(500))
        backoff.next()!.shouldEqual(.milliseconds(750))
        backoff.next()!.shouldEqual(.milliseconds(1125))
        backoff.next().shouldBeNil()
        backoff.next().shouldBeNil()
        backoff.next().shouldBeNil()
    }

    func test_exponentialBackoff_withLargeInitial_shouldAdjustCap() {
        _ = Backoff.exponential(initialInterval: .seconds(60))  // cap used to be hardcoded which would cause this to precondition crash
    }
}
