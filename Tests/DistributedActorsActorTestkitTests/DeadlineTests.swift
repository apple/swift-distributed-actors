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
import NIO
@testable import Swift Distributed ActorsActorTestkit

class DeadlineTests: XCTestCase {


  func test_deadline_nowIsNotPastNow() {
    let now = Date()
    let beforeDeadline = now - 100
    let pastDeadline = now + 10

    let deadline = Deadline(instant: now)
    deadline.isOverdue(now: Date.distantPast).shouldBeFalse()
    deadline.isOverdue(now: beforeDeadline).shouldBeFalse()
    deadline.isOverdue(now: now).shouldBeFalse()
    deadline.isOverdue(now: pastDeadline).shouldBeTrue()
    deadline.isOverdue(now: Date.distantFuture).shouldBeFalse()
  }

  func test_deadline_remainingShouldReturnExpectedTimeAmounts() {
    let now = Date()

    let t1Millis = 12
    let t1 = TimeAmount.milliseconds(t1Millis)
    let d1 = Deadline(instant: now.addingTimeInterval(TimeInterval(exactly: t1Millis)!))
    d1.remainingFrom(now).prettyDescription().shouldEqual(t1.prettyDescription())

    let t2Millis = 1200
    let t2 = TimeAmount.milliseconds(t2Millis)
    let d2 = Deadline(instant: now.addingTimeInterval(TimeInterval(exactly: t2Millis)!))
    d2.remainingFrom(now).prettyDescription().shouldEqual(t2.prettyDescription())
  }
}
