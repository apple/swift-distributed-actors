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

struct DeadlineTests {
    
    @Test
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

    @Test
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

    @Test
    func test_deadline_subtracting() {
        let older = ContinuousClock.Instant.now
        Thread.sleep(until: Date().addingTimeInterval(0.02))
        let newer = ContinuousClock.Instant.now

        #expect(older - newer < .nanoseconds(0))
        #expect(newer - older > .nanoseconds(0))
    }

    @Test
    func test_fromNow() {
        let now = ContinuousClock.Instant.now
        let deadline = ContinuousClock.Instant.fromNow(.seconds(3))

        #expect(now < deadline)
    }
}
