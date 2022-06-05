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

import DistributedActorsTestKit
import Foundation
import XCTest

@testable import DistributedActors

final class _StashBufferTests: ClusterSystemXCTestCase {
    func test_stash_shouldStashMessages() throws {
        let probe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let unstashBehavior: _Behavior<Int> = .receiveMessage { message in
            probe.ref.tell(message)
            return .same
        }

        let behavior: _Behavior<Int> = .setup { _ in
            let stash: _StashBuffer<Int> = _StashBuffer(capacity: 100)
            return .receive { context, message in
                switch message {
                case 10:
                    return try stash.unstashAll(context: context, behavior: unstashBehavior)
                default:
                    // TODO: use `try` once we have supervision and behaviors can throw
                    try! stash.stash(message: message)
                    return .same
                }
            }
        }

        let stasher = try system._spawn(.anonymous, behavior)

        for i in 0 ... 10 {
            stasher.tell(i)
        }

        for i in 0 ... 9 {
            try probe.expectMessage(i)
        }

        stasher.tell(10)
        try probe.expectMessage(10)
    }

    func test_fullStash_shouldThrowWhenAttemptToStashSomeMore() throws {
        let stash: _StashBuffer<Int> = _StashBuffer(capacity: 1)

        try stash.stash(message: 1)

        try shouldThrow(expected: _StashError.self) {
            _ = try stash.stash(message: 2)
        }
    }

    func test_unstash_intoSetupBehavior_shouldCanonicalize() throws {
        let p = self.testKit.makeTestProbe(expecting: Int.self)

        _ = try self.system._spawn(
            "unstashIntoSetup",
            _Behavior<Int>.setup { context in
                let stash = _StashBuffer<Int>(capacity: 2)
                try stash.stash(message: 1)

                return try stash.unstashAll(
                    context: context,
                    behavior: .setup { _ in
                        .receiveMessage { message in
                            p.tell(message)
                            return .stop
                        }
                    }
                )
            }
        )

        try p.expectMessage(1)
    }

    func test_messagesStashedAgainDuringUnstashingShouldNotBeProcessedInTheSameRun() throws {
        let probe: ActorTestProbe<Int> = self.testKit.makeTestProbe()

        let stash: _StashBuffer<Int> = _StashBuffer(capacity: 100)

        let unstashBehavior: _Behavior<Int> = .receiveMessage { message in
            try! stash.stash(message: message)
            probe.ref.tell(message)
            return .same
        }

        let behavior: _Behavior<Int> = .receive { context, message in
            switch message {
            case 10:
                return try stash.unstashAll(context: context, behavior: unstashBehavior)
            default:
                // TODO: use `try` once we have supervision and behaviors can throw
                try! stash.stash(message: message)
                return .same
            }
        }

        let stasher = try system._spawn(.anonymous, behavior)

        for i in 0 ... 10 {
            stasher.tell(i)
        }

        // we are expecting to get each stashed message once
        for i in 0 ... 9 {
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
