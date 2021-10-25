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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import Foundation
import XCTest

final class ActorLeakingTests: ActorSystemXCTestCase {
    struct NotEnoughActorsAlive: Error {
        let expected: Int
        let current: Int
    }

    struct TooManyActorsAlive: Error {
        let expected: Int
        let current: Int
    }

    func test_spawn_stop_shouldNotLeakActors() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let stopsOnAnyMessage: _Behavior<String> = .receiveMessage { _ in
            .stop
        }

        var ref: _ActorRef<String>? = try system._spawn("printer", stopsOnAnyMessage)

        let afterStartActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartActorCount.shouldEqual(1)
        afterStopActorCount.shouldEqual(0)
        #endif
    }

    func test_spawn_stop_shouldNotLeakActorThatCloseOverContext() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let stopsOnAnyMessage: _Behavior<String> = .setup { context in
            .receiveMessage { _ in
                context.log.debug("just so we actually close over context ;)")
                return .stop
            }
        }

        var ref: _ActorRef<String>? = try system._spawn("printer", stopsOnAnyMessage)

        let afterStartActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartActorCount.shouldEqual(1)
        afterStopActorCount.shouldEqual(0)
        #endif
    }

    func test_spawn_stop_shouldNotLeakMailbox() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let stopsOnAnyMessage: _Behavior<String> = .receiveMessage { _ in
            .stop
        }

        var ref: _ActorRef<String>? = try system._spawn("stopsOnAnyMessage", stopsOnAnyMessage)

        let afterStartMailboxCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userMailboxInitCounter.load()
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopMailboxCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userMailboxInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartMailboxCount.shouldEqual(1)
        afterStopMailboxCount.shouldEqual(0)

        #endif
    }

    func test_parentWithChildrenStopping_shouldNotLeakActors() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let spawnsNChildren: _Behavior<Int> = .receive { context, childCount in
            if childCount == 0 {
                return .stop
            } else {
                for _ in 1 ... childCount {
                    let b: _Behavior<String> = .receiveMessage { _ in .same }
                    try context._spawn(.anonymous, b)
                }
                return .same
            }
        }

        var ref: _ActorRef<Int>? = try system._spawn("printer", spawnsNChildren)

        let expectedParentCount = 1
        let expectedChildrenCount = 3
        let expectedActorCount = expectedParentCount + expectedChildrenCount

        ref?.tell(expectedChildrenCount)

        let afterStartActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != expectedActorCount {
                throw NotEnoughActorsAlive(expected: expectedActorCount, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell(0) // stops the parent actor
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartActorCount.shouldEqual(expectedActorCount)
        afterStopActorCount.shouldEqual(0)
        #endif
    }

    final class LeakTestMessage {
        let deallocated: Atomic<Bool>?

        init(_ deallocated: Atomic<Bool>?) {
            self.deallocated = deallocated
        }

        deinit {
            deallocated?.store(true)
        }
    }

    func test_droppedMessages_shouldNotLeak() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let lock = _Mutex()
        lock.lock()
        let behavior: _Behavior<LeakTestMessage> = .receiveMessage { _ in
            lock.lock()
            return .stop
        }
        let ref = try system._spawn(.anonymous, props: Props().mailbox(MailboxProps.default(capacity: 1)), behavior)

        // this will cause the actor to block and fill the mailbox, so the next message should be dropped and deallocated
        ref.tell(LeakTestMessage(nil))

        let deallocated: Atomic<Bool> = Atomic(value: false)
        ref.tell(LeakTestMessage(deallocated))

        deallocated.load().shouldBeTrue()
        lock.unlock()
        #endif // SACT_TESTS_LEAKS
    }

    func test_actorSystem_shouldNotLeak() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): we need to manage the retain cycles with the receptionist better

        let initialSystemCount = ActorSystem.actorSystemInitCounter.load()

        for n in 1 ... 5 {
            let system = ActorSystem("Test-\(n)")
            try! system.shutdown().wait()
        }

        ActorSystem.actorSystemInitCounter.load().shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    func test_releasing_ActorSystem_mustNotLeaveActorsReferringToANilSystemFromContext() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        var system: ActorSystem? = ActorSystem("FreeMe") // only "reference from user land" to the system

        let p = self.testKit.makeTestProbe(expecting: String.self)

        let ref = try system!._spawn("echo", of: String.self, .receive { context, message in
            if message == "shutdown" {
                context.system.shutdown()
            }
            p.tell("system:\(context.system)")
            return .same
        })

        ref.tell("x")
        try p.expectMessage("system:ActorSystem(FreeMe)")

        // clear the strong reference from "user land"
        system = nil

        ref.tell("x")
        try p.expectMessage("system:ActorSystem(FreeMe)")

        ref.tell("shutdown") // since we lost the `system` reference here we'll ask the actor to stop the system

        #endif // SACT_TESTS_LEAKS
    }

    func test_actor_whichLogsShouldNotCauseLeak_onDisabledLevel() throws {
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): disabled test

        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let initialSystemCount = ActorSystem.actorSystemInitCounter.load()

        var system: ActorSystem? = ActorSystem("Test") { settings in
            settings.logging.logLevel = .info
        }
        _ = try system?._spawn("logging", of: String.self, .setup { context in
            context.log.trace("Not going to be logged")
            return .receiveMessage { _ in .same }
        })
        try! system?.shutdown().wait()
        system = nil

        ActorSystem.actorSystemInitCounter.load().shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    func test_actor_whichLogsShouldNotCauseLeak_onEnabled() throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): we need to manage the retain cycles with the receptionist better

        let initialSystemCount = ActorSystem.actorSystemInitCounter.load()

        var system: ActorSystem? = ActorSystem("Test") { settings in
            settings.logging.logLevel = .info
        }
        _ = try system?._spawn("logging", of: String.self, .setup { context in
            context.log.warning("Not going to be logged")
            return .receiveMessage { _ in .same }
        })
        try! system?.shutdown().wait()
        system = nil

        ActorSystem.actorSystemInitCounter.load().shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    private func skipLeakTests(function: String = #function) {
        pnote("Skipping leak test \(function), it will only be executed if -DSACT_TESTS_LEAKS is enabled.")
    }
}

extension ActorLeakingTests.LeakTestMessage: Codable {
    public enum CodingKeys: CodingKey {
        case _deallocated
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Bool.self, forKey: CodingKeys._deallocated)
        self.init(Atomic(value: value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deallocated?.load() ?? false, forKey: CodingKeys._deallocated)
    }
}
