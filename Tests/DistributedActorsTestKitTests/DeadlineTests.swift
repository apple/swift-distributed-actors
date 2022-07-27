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

@testable import DistributedActors
@testable import DistributedActorsTestKit
import Foundation
import XCTest

class DeadlineTests: XCTestCase {
    func test_deadline_nowIsNotPastNow() {
        let now = ContinuousClock.Instant.now
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.isBefore(.distantPast).shouldBeFalse()
        now.isBefore(beforeDeadline).shouldBeFalse()
        now.isBefore(now).shouldBeFalse()
        now.isBefore(pastDeadline).shouldBeTrue()
        now.isBefore(.distantFuture).shouldBeTrue()
    }

    func test_deadline_hasTimeLeft() {
        let now = ContinuousClock.Instant.now
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.hasTimeLeft(until: .distantPast).shouldBeTrue()
        now.hasTimeLeft(until: beforeDeadline).shouldBeTrue()
        now.hasTimeLeft(until: pastDeadline).shouldBeFalse()
        now.hasTimeLeft(until: now).shouldBeTrue()
        now.hasTimeLeft(until: .distantFuture).shouldBeFalse()
    }

    func test_deadline_subtracting() {
        let older = ContinuousClock.Instant.now
        Thread.sleep(until: Date().addingTimeInterval(0.02))
        let newer = ContinuousClock.Instant.now

        XCTAssertLessThan(older - newer, .nanoseconds(0))
        XCTAssertGreaterThan(newer - older, .nanoseconds(0))
    }

    func test_fromNow() {
        let now = ContinuousClock.Instant.now
        let deadline = ContinuousClock.Instant.fromNow(.seconds(3))

        XCTAssert(now < deadline)
    }
}
