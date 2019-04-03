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

class TimersTests: XCTestCase {

    let system = ActorSystem("System")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
    }

    func test_startSingleTimer_shouldSendSingleMessage() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.timers.startSingleTimer(key: "message", message: "fromTimer", delay: .microseconds(100))
            return .receiveMessage { message in
                p.tell(message)
                return .same
            }
        }

        _ = try system.spawnAnonymous(behavior)
        try p.expectMessage("fromTimer")
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_startPeriodicTimer_shouldSendPeriodicMessage() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            var i = 0
            context.timers.startPeriodicTimer(key: "message", message: "fromTimer", interval: .milliseconds(10))
            return .receiveMessage { message in
                i += 1
                p.tell(message)

                if i >= 5 {
                    return .stopped
                } else {
                    return .same
                }
            }
        }

        _ = try system.spawnAnonymous(behavior)
        for _ in 0..<5 {
            try p.expectMessage("fromTimer")
        }
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_periodicTimer_shouldStopWhenCanceled() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            var i = 0
            context.timers.startPeriodicTimer(key: "message", message: "fromTimer", interval: .milliseconds(10))
            return .receiveMessage { message in
                i += 1
                p.tell(message)

                if i >= 5 {
                    context.timers.cancelTimer(forKey: "message")
                }
                return .same
            }
        }

        _ = try system.spawnAnonymous(behavior)
        for _ in 0..<5 {
            try p.expectMessage("fromTimer")
        }
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_singleTimer_shouldStopWhenCanceled() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior = Behavior<String>.setup { context in
            // We start the timer without delay and then sleep for a short
            // amount of time, so the timer is triggered and sends the message.
            // Because we cancel the timer in the same run, the message should
            // not be processed and the probe should not receive a message.
            context.timers.startSingleTimer(key: "message", message: "fromTimer", delay: .nanoseconds(0))
            Swift Distributed ActorsActor.Thread.sleep(.milliseconds(10))
            context.timers.cancelTimer(forKey: "message")
            return .receiveMessage { message in
                p.tell(message)
                return .same
            }
        }

        _ = try system.spawnAnonymous(behavior)
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_timers_cancelAllShouldStopAllTimers() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.timers.startPeriodicTimer(key: "message", message: "fromTimer", interval: .milliseconds(10))
            context.timers.startPeriodicTimer(key: "message2", message: "fromTimer2", interval: .milliseconds(50))
            context.timers.startPeriodicTimer(key: "message3", message: "fromTimer3", interval: .milliseconds(50))
            return .receiveMessage { message in
                p.tell(message)
                context.timers.cancelAll()
                return .same
            }
        }

        _ = try system.spawnAnonymous(behavior)
        try p.expectMessage("fromTimer")
        try p.expectNoMessage(for: .milliseconds(100))
    }
}
