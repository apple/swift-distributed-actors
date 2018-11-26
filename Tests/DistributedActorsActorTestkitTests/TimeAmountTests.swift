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
@testable import Swift Distributed ActorsActorTestkit
import NIO

class TimeAmountTests: XCTestCase {

    func test_timeAmount_rendersPrettyDurations() {
        TimeAmount.nanoseconds(12).prettyDescription.shouldEqual("12ns")
        TimeAmount.microseconds(12).prettyDescription.shouldEqual("12μs")
        TimeAmount.milliseconds(12).prettyDescription.shouldEqual("12ms")
        TimeAmount.seconds(12).prettyDescription.shouldEqual("12s")
        TimeAmount.seconds(60).prettyDescription.shouldEqual("1m")
        TimeAmount.seconds(90).prettyDescription.shouldEqual("1m 30s")
        TimeAmount.minutes(60).prettyDescription.shouldEqual("1h")
        TimeAmount.hours(2).prettyDescription.shouldEqual("2h")
        TimeAmount.hours(24).prettyDescription.shouldEqual("1d")
    }
}
