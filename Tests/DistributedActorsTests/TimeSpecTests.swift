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
import DistributedActorsTestTools
import XCTest

private let NANOS = 1_000_000_000

class TimeSpecTests: XCTestCase {
    let nanosAmount: TimeAmount = .nanoseconds(100)
    let secondsAmount: TimeAmount = .seconds(2)
    var totalAmount: TimeAmount {
        return self.secondsAmount + self.nanosAmount
    }

    var nanos: TimeSpec {
        return .from(timeAmount: self.nanosAmount)
    }

    var seconds: TimeSpec {
        return .from(timeAmount: self.secondsAmount)
    }

    var total: TimeSpec {
        return .from(timeAmount: self.totalAmount)
    }

    func test_timeSpecShouldBeCreatedProperlyFromTimeAmount() {
        self.total.toNanos().shouldEqual(Int(self.totalAmount.nanoseconds))
        self.total.tv_sec.shouldEqual(Int(self.totalAmount.nanoseconds) / NANOS)
        self.total.tv_nsec.shouldEqual(Int(self.totalAmount.nanoseconds) % NANOS)
    }

    func test_timeSpecAdd() {
        let sum = self.nanos + self.seconds

        sum.shouldEqual(self.total)
    }

    func test_lessThan() {
        XCTAssertTrue(self.nanos < self.seconds)
        XCTAssertFalse(self.seconds < self.nanos)
        XCTAssertFalse(self.total < self.total)
    }

    func test_greaterThan() {
        XCTAssertFalse(self.nanos > self.seconds)
        XCTAssertTrue(self.seconds > self.nanos)
    }

    func test_equals() {
        XCTAssertFalse(self.nanos == self.seconds)
        XCTAssertFalse(self.seconds == self.nanos)

        XCTAssertTrue(self.nanos == self.nanos)
        XCTAssertTrue(self.seconds == self.seconds)
        XCTAssertTrue(self.total == self.total)
    }
}
