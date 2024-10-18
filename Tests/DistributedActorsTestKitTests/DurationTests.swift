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

@testable import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Testing

struct DurationTests {
    
    @Test
    func test_duration_rendersPrettyDurations() {
        Duration.nanoseconds(12).prettyDescription.shouldEqual("12ns")
        Duration.microseconds(12).prettyDescription.shouldEqual("12μs")
        Duration.milliseconds(12).prettyDescription.shouldEqual("12ms")
        Duration.seconds(12).prettyDescription.shouldEqual("12s")
        Duration.seconds(60).prettyDescription.shouldEqual("1m")
        Duration.seconds(90).prettyDescription.shouldEqual("1m 30s")
        Duration.minutes(60).prettyDescription.shouldEqual("1h")
        Duration.hours(2).prettyDescription.shouldEqual("2h")
        Duration.hours(24).prettyDescription.shouldEqual("1d")
    }
}
