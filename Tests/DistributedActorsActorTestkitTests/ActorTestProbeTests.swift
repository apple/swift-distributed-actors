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
@testable import Swift Distributed ActorsActorTestkit
import XCTest

class ActorTestProbeTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")

  override func tearDown() {
    // Await.on(system.terminate())
  }

  func test_testProbe_expectMessage_shouldFailWhenNoMessageSentWithinTimeout() {
    #if !SACT_TESTS_CRASH
    pnote("Skipping test \(#function), can't test assert(); To see it crash run with `-D SACT_TESTS_CRASH`")
    return ()
    #endif
    let _ = "Won't execute since SACT_TESTS_CRASH is not set. This test would crash since we can't capture the failures."

    let probe: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

    probe.expectMessage("awaiting-forever")
    // this causes a nice failure like:
    //    /Users/ktoso/code/sact/Tests/Swift Distributed ActorsActorTestkitTests/ActorTestProbeTests.swift:35: error: -[Swift Distributed ActorsActorTestkitTests.ActorTestProbeTests test_testProbe_expectMessage_shouldFailWhenNoMessageSentWithinTimeout] : XCTAssertTrue failed -
    //        try! probe.expectMessage("awaiting-forever")
    //                   ^~~~~~~~~~~~~~
    //    error: Did not receive expected [awaiting-forever]:String within [1s], error: noMessagesInQueue
  }

  func test_testProbe_expectMessage_shouldFailWhenWrongMessageReceived() {
    #if !SACT_TESTS_CRASH
    pnote("Skipping test \(#function), can't test assert(); To see it crash run with `-D SACT_TESTS_CRASH`")
    return ()
    #endif
    let _ = "Won't execute since SACT_TESTS_CRASH is not set. This test would crash since we can't capture the failures."

    let probe: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

    probe ! "one"

    probe.expectMessage("two") // TODO style question if we want to enforce `try! ...`? It does not throw but log XCTest errors
    // this causes a nice failure like:
    //    /Users/ktoso/code/sact/Tests/Swift Distributed ActorsActorTestkitTests/ActorTestProbeTests.swift:48: error: -[Swift Distributed ActorsActorTestkitTests.ActorTestProbeTests test_testProbe_expectMessage_shouldFailWhenWrongMessageReceived] : XCTAssertEqual failed: ("one") is not equal to ("two") -
    //        try! probe.expectMessage("two")
    //                   ^~~~~~~~~~~~
    //    error: Assertion failed: [one] did not equal expected [two]

  }

  func test_expectNoMessage() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-6", on: system)

    p.expectNoMessage(for: .milliseconds(100))
  }
}
