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
@testable import SwiftDistributedActorsActorTestKit
import Swift Distributed ActorsActor

class DeadlineTests: XCTestCase {


    func test_deadline_nowIsNotPastNow() {
        let now = Deadline.now()
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.isOverdue(Deadline.distantPast).shouldBeFalse()
        now.isOverdue(beforeDeadline).shouldBeFalse()
        now.isOverdue(now).shouldBeFalse()
        now.isOverdue(pastDeadline).shouldBeTrue()
        now.isOverdue(Deadline.distantFuture).shouldBeTrue()
    }

    func test_deadline_remainingShouldReturnExpectedTimeAmounts() {
        let now = Deadline.now()

        let t1Millis = 12000
        let t1 = TimeAmount.milliseconds(Int64(t1Millis))
        let d1 = now + .milliseconds(t1Millis)

        let t2Millis = 1200000
        let t2 = TimeAmount.milliseconds(t2Millis)
        let d2 = now + .milliseconds(t2Millis)
    }

    func test_deadline_hasTimeLeft() {
        let now = Deadline.now()
        let beforeDeadline = now - .seconds(100)
        let pastDeadline = now + .seconds(10)

        now.hasTimeLeft(Deadline.distantPast).shouldBeTrue()
        now.hasTimeLeft(beforeDeadline).shouldBeTrue()
        now.hasTimeLeft(pastDeadline).shouldBeFalse()
        now.hasTimeLeft(now).shouldBeTrue()
        now.hasTimeLeft(Deadline.distantFuture).shouldBeFalse()
    }

    func test_fromNow() {
        let now = Deadline.now()
        let deadline = Deadline.fromNow(.seconds(3))

        XCTAssert(now < deadline)
    }
}
