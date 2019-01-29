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
import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

fileprivate let NANOS = 1_000_000_000

class TimeSpecTests: XCTestCase {
    let nanosAmount: TimeAmount = .nanoseconds(100)
    let secondsAmount: TimeAmount = .seconds(2)
    var totalAmount: TimeAmount {
        return self.secondsAmount + self.nanosAmount
    }

    var nanos: TimeSpec {
        return .from(timeAmount: nanosAmount)
    }

    var seconds: TimeSpec {
        return .from(timeAmount: secondsAmount)
    }

    var total: TimeSpec {
        return .from(timeAmount: totalAmount)
    }

    func test_timeSpecShouldBeCreatedProperlyFromTimeAmount() {
        total.toNanos().shouldEqual(Int(totalAmount.nanoseconds))
        total.tv_sec.shouldEqual(Int(totalAmount.nanoseconds) / NANOS)
        total.tv_nsec.shouldEqual(Int(totalAmount.nanoseconds) % NANOS)
    }

    func test_timeSpecAdd() {
        let sum = nanos + seconds

        sum.shouldEqual(total)
    }

    func test_lessThan() {
        XCTAssertTrue(nanos < seconds)
        XCTAssertFalse(seconds < nanos)
        XCTAssertFalse(total < total)
    }

    func test_greaterThan() {
        XCTAssertFalse(nanos > seconds)
        XCTAssertTrue(seconds > nanos)
    }

    func test_equals() {
        XCTAssertFalse(nanos == seconds)
        XCTAssertFalse(seconds == nanos)

        XCTAssertTrue(nanos == nanos)
        XCTAssertTrue(seconds == seconds)
        XCTAssertTrue(total == total)
    }
}
