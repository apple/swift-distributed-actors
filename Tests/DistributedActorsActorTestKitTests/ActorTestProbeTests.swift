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

import Swift Distributed ActorsActor
@testable import SwiftDistributedActorsActorTestKit
import XCTest

class ActorTestProbeTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
    }

    func test_testProbe_expectMessage_shouldFailWhenNoMessageSentWithinTimeout() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function), can't test assert(); To see it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \(#function), can't test the 'test assertions' being emitted; To see it crash run with `-D SACT_TESTS_CRASH`"

        let probe = testKit.spawnTestProbe(name: "p1", expecting: String.self)

        try probe.expectMessage("awaiting-forever")
    }

    func test_testProbe_expectMessage_shouldFailWhenWrongMessageReceived() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function), can't test the 'test assertions' being emitted; To see it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \(#function), can't test the 'test assertions' being emitted; To see it crash run with `-D SACT_TESTS_CRASH`"

        let probe = testKit.spawnTestProbe(name: "p2", expecting: String.self)

        probe.tell("one")

        try probe.expectMessage("two") // TODO: style question if we want to enforce `try! ...`? It does not throw but log XCTest errors
        // this causes a nice failure like:
        //    /Users/ktoso/code/sact/Tests/Swift Distributed ActorsActorTestKitTests/ActorTestProbeTests.swift:48: error: -[Swift Distributed ActorsActorTestKitTests.ActorTestProbeTests test_testProbe_expectMessage_shouldFailWhenWrongMessageReceived] : XCTAssertEqual failed: ("one") is not equal to ("two") -
        //        try! probe.expectMessage("two")
        //                   ^~~~~~~~~~~~
        //    error: Assertion failed: [one] did not equal expected [two]

    }

    func test_expectNoMessage() throws {
        let p = testKit.spawnTestProbe(name: "p3", expecting: String.self)

        try p.expectNoMessage(for: .milliseconds(100))
        p.stop()
    }

    func test_probe_shouldBeWatchable() throws {
        let watchedProbe = testKit.spawnTestProbe(expecting: Never.self)
        let watchingProbe = testKit.spawnTestProbe(expecting: Never.self)

        watchingProbe.watch(watchedProbe.ref)

        watchedProbe.stop()

        try watchingProbe.expectTerminated(watchedProbe.ref)
    }

    func test_probe_expectMessageAnyOrderSuccess() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)
        let messages = ["test1", "test2", "test3", "test4"]

        for message in messages.reversed() {
            p.ref.tell(message)
        }

        try p.expectMessagesInAnyOrder(messages)
    }
}
