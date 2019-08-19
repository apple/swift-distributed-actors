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

import XCTest
import Foundation
@testable import DistributedActorsTestKit
import DistributedActors

class DeadlineTests: XCTestCase {

    func test_deadline_nowIsNotPastNow() {
        let now = Deadline.now()
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.isBefore(Deadline.distantPast).shouldBeFalse()
        now.isBefore(beforeDeadline).shouldBeFalse()
        now.isBefore(now).shouldBeFalse()
        now.isBefore(pastDeadline).shouldBeTrue()
        now.isBefore(Deadline.distantFuture).shouldBeTrue()
    }

    func test_deadline_remainingShouldReturnExpectedTimeAmounts() {
        let now = Deadline.now()

        let t1Millis = 12000
        let d1 = now + .milliseconds(t1Millis)

        let t2Millis = 1200000
        let d2 = now + .milliseconds(t2Millis)

        d1.isBefore(d2).shouldBeTrue()
    }

    func test_deadline_hasTimeLeft() {
        let now = Deadline.now()
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.hasTimeLeft(until: Deadline.distantPast).shouldBeTrue()
        now.hasTimeLeft(until: beforeDeadline).shouldBeTrue()
        now.hasTimeLeft(until: pastDeadline).shouldBeFalse()
        now.hasTimeLeft(until: now).shouldBeTrue()
        now.hasTimeLeft(until: Deadline.distantFuture).shouldBeFalse()
    }

    func test_deadline_subtracting() {
        let older = Deadline.now()
        Thread.sleep(until: Date().addingTimeInterval(0.02))
        let newer = Deadline.now()

        XCTAssertLessThan(older - newer, .nanoseconds(0))
        XCTAssertGreaterThan(newer - older, .nanoseconds(0))
    }

    func test_fromNow() {
        let now = Deadline.now()
        let deadline = Deadline.fromNow(.seconds(3))

        XCTAssert(now < deadline)
    }
}
