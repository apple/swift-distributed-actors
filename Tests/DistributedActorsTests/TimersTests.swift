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

class TimersTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
        self.system = nil
        self.testKit = nil
    }

    func test_timerKey_shouldPrintNicely() {
        TimerKey("Hello").description.shouldEqual("TimerKey(Hello)")
        TimerKey("Hello", isSystemTimer: true).description.shouldEqual("TimerKey(Hello, isSystemTimer: true)")
    }

    func test_startSingleTimer_shouldSendSingleMessage() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.timers.startSingle(key: TimerKey("message"), message: "fromTimer", delay: .microseconds(100))
            return .receiveMessage { message in
                p.tell(message)
                return .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)
        try p.expectMessage("fromTimer")
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_startPeriodicTimer_shouldSendPeriodicMessage() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            var i = 0
            context.timers.startPeriodic(key: TimerKey("message"), message: "fromTimer", interval: .milliseconds(10))
            return .receiveMessage { message in
                i += 1
                p.tell(message)

                if i >= 5 {
                    return .stop
                } else {
                    return .same
                }
            }
        }

        _ = try system.spawn(.anonymous, behavior)
        for _ in 0 ..< 5 {
            try p.expectMessage("fromTimer")
        }
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_periodicTimer_shouldStopWhenCanceled() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            var i = 0
            context.timers.startPeriodic(key: TimerKey("message"), message: "fromTimer", interval: .milliseconds(10))
            return .receiveMessage { message in
                i += 1
                p.tell(message)

                if i >= 5 {
                    context.timers.cancel(for: TimerKey("message"))
                }
                return .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)
        for _ in 0 ..< 5 {
            try p.expectMessage("fromTimer")
        }
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_singleTimer_shouldStopWhenCanceled() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior = Behavior<String>.setup { context in
            // We start the timer without delay and then sleep for a short
            // amount of time, so the timer is triggered and sends the message.
            // Because we cancel the timer in the same run, the message should
            // not be processed and the probe should not receive a message.
            context.timers.startSingle(key: TimerKey("message"), message: "fromTimer", delay: .nanoseconds(0))
            DistributedActors.Thread.sleep(.milliseconds(10))
            context.timers.cancel(for: TimerKey("message"))
            return .receiveMessage { message in
                p.tell(message)
                return .same
            }
        }

        _ = try self.system.spawn(.anonymous, behavior)
        try p.expectNoMessage(for: .milliseconds(10))
    }

    func test_timers_cancelAllShouldStopAllTimers() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.timers.startPeriodic(key: TimerKey("message"), message: "fromTimer", interval: .milliseconds(10))
            context.timers.startPeriodic(key: TimerKey("message2"), message: "fromTimer2", interval: .milliseconds(50))
            context.timers.startPeriodic(key: TimerKey("message3"), message: "fromTimer3", interval: .milliseconds(50))
            return .receiveMessage { message in
                p.tell(message)
                context.timers.cancelAll()
                return .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)
        try p.expectMessage("fromTimer")
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_timers_cancelAllShouldNotStopSystemTimers() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { context in
            context.timers.startPeriodic(key: TimerKey("message", isSystemTimer: true), message: "fromSystemTimer", interval: .milliseconds(10))
            return .receiveMessage { message in
                p.tell(message)
                context.timers.cancelAll()
                return .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)
        try p.expectMessage("fromSystemTimer")
        try p.expectMessage("fromSystemTimer")
        try p.expectMessage("fromSystemTimer")
        try p.expectMessage("fromSystemTimer")
    }
}
