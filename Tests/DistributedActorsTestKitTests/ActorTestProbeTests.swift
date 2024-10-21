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
import DistributedCluster
import Testing

@Suite(.serialized)
final class ActorTestProbeTests: Sendable {
    
    let testCase: SingleClusterSystemTestCase
    
    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }
    
    @Test
    func test_maybeExpectMessage_shouldReturnTheReceivedMessage() throws {
        let probe = self.testCase.testKit.makeTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    @Test
    func test_maybeExpectMessage_shouldReturnNilIfTimeoutExceeded() throws {
        let probe = self.testCase.testKit.makeTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    @Test
    func test_expectNoMessage() throws {
        let p = self.testCase.testKit.makeTestProbe("p3", expecting: String.self)

        try p.expectNoMessage(for: .milliseconds(100))
        p.stop()
    }

    @Test
    func test_shouldBeWatchable() throws {
        let watchedProbe = self.testCase.testKit.makeTestProbe(expecting: Never.self)
        let watchingProbe = self.testCase.testKit.makeTestProbe(expecting: Never.self)

        watchingProbe.watch(watchedProbe.ref)

        watchedProbe.stop()

        try watchingProbe.expectTerminated(watchedProbe.ref)
    }

    @Test
    func test_expectMessageAnyOrderSuccess() async throws {
        let p = self.testCase.testKit.makeTestProbe(expecting: String.self)
        let messages = ["test1", "test2", "test3", "test4"]

        for message in messages.reversed() {
            p.ref.tell(message)
        }

        try p.expectMessagesInAnyOrder(messages)
    }
}
