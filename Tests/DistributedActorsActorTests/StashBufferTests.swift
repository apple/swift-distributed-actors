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

import Foundation
import XCTest
import SwiftDistributedActorsActorTestKit

@testable import Swift Distributed ActorsActor

class StashBufferTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        system.shutdown()
    }

    func test_stash_shouldStashMessages() throws {
        let probe: ActorTestProbe<Int> = testKit.spawnTestProbe()

        let unstashBehavior: Behavior<Int> = .receiveMessage { message in
            probe.ref.tell(message)
            return .same
        }

        let behavior: Behavior<Int> = .setup { _ in
            let stash: StashBuffer<Int> = StashBuffer(capacity: 100)
            return .receive { (context, message) in
                switch message {
                case 10:
                    return try stash.unstashAll(context: context, behavior: unstashBehavior)
                default:
                    //TODO: use `try` once we have supervision and behaviors can throw
                    try! stash.stash(message: message)
                    return .same
                }
            }
        }

        let stasher = try system.spawnAnonymous(behavior)

        for i in 0...10 {
            stasher.tell(i)
        }

        for i in 0...9 {
            try probe.expectMessage(i)
        }

        stasher.tell(10)
        try probe.expectMessage(10)
    }

    func test_fullStash_shouldThrowWhenAttemptToStashSomeMore() throws {
        let stash: StashBuffer<Int> = StashBuffer(capacity: 1)

        try stash.stash(message: 1)

        shouldThrow(expected: StashError.self) {
            _ = try stash.stash(message: 2)
        }
    }

    func test_unstash_intoSetupBehavior_shouldCanonicalize() throws {
        let p = testKit.spawnTestProbe(expecting: Int.self)

        _ = try system.spawn(Behavior<Int>.setup { context in
            let stash = StashBuffer<Int>(capacity: 2)
            try stash.stash(message: 1)

            return try stash.unstashAll(context: context, behavior: .setup { _ in
                .receiveMessage { message in
                    p.tell(message)
                    return .stop
                }
            })
        }, name: "unstashIntoSetup")

        try p.expectMessage(1)
    }

    func test_messagesStashedAgainDuringUnstashingShouldNotBeProcessedInTheSameRun() throws {
        let probe: ActorTestProbe<Int> = testKit.spawnTestProbe()

        let stash: StashBuffer<Int> = StashBuffer(capacity: 100)

        let unstashBehavior: Behavior<Int> = .receiveMessage { message in
            try! stash.stash(message: message)
            probe.ref.tell(message)
            return .same
        }

        let behavior: Behavior<Int> = .receive { (context, message) in
            switch message {
            case 10:
                return try stash.unstashAll(context: context, behavior: unstashBehavior)
            default:
                //TODO: use `try` once we have supervision and behaviors can throw
                try! stash.stash(message: message)
                return .same
            }
        }

        let stasher = try system.spawnAnonymous(behavior)

        for i in 0...10 {
            stasher.tell(i)
        }

        // we are expecting to get each stashed message once
        for i in 0...9 {
            try probe.expectMessage(i)
        }

        // No we send another message, that should be send back to us.
        // If the stash would unstash the messages that have been stashed
        // during the same unstash run, we should get 0 instead of 10 and the
        // test would fail.
        stasher.tell(10)
        try probe.expectMessage(10)
    }
}
