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

import DistributedActors
@testable import DistributedActorsTestKit
import XCTest

final class ActorTestProbeTests: SingleClusterSystemXCTestCase {

    func test_maybeExpectMessage_shouldReturnTheReceivedMessage() throws {
        let probe = self.testKit.makeTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    func test_maybeExpectMessage_shouldReturnNilIfTimeoutExceeded() throws {
        let probe = self.testKit.makeTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    func test_expectNoMessage() throws {
        let p = self.testKit.makeTestProbe("p3", expecting: String.self)

        try p.expectNoMessage(for: .milliseconds(100))
        p.stop()
    }

    func test_shouldBeWatchable() throws {
        let watchedProbe = self.testKit.makeTestProbe(expecting: Never.self)
        let watchingProbe = self.testKit.makeTestProbe(expecting: Never.self)

        watchingProbe.watch(watchedProbe.ref)

        watchedProbe.stop()

        try watchingProbe.expectTerminated(watchedProbe.ref)
    }

    func test_expectMessageAnyOrderSuccess() async throws {
        let p = self.testKit.makeTestProbe(expecting: String.self)
        let messages = ["test1", "test2", "test3", "test4"]

        for message in messages.reversed() {
            p.ref.tell(message)
        }

        try p.expectMessagesInAnyOrder(messages)
    }
}
