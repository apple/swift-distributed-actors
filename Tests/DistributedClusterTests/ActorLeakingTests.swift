//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import XCTest

final class ActorLeakingTests: SingleClusterSystemXCTestCase {
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
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
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
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
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
            let counter = self.system.userMailboxInitCounter.load(ordering: .relaxed)
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopMailboxCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userMailboxInitCounter.load(ordering: .relaxed)
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
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
            if counter != expectedActorCount {
                throw NotEnoughActorsAlive(expected: expectedActorCount, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell(0) // stops the parent actor
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.userCellInitCounter.load(ordering: .relaxed)
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
        let deallocated: UnsafeAtomic<Bool>?

        init(_ deallocated: UnsafeAtomic<Bool>?) {
            self.deallocated = deallocated
        }

        deinit {
            deallocated?.store(true, ordering: .relaxed)
        }
    }

    func test_ClusterSystem_shouldNotLeak() async throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): we need to manage the retain cycles with the receptionist better #831

        let initialSystemCount = ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed)

        for n in 1 ... 5 {
            let system = await ClusterSystem("Test-\(n)")
            try! await system.shutdown().wait()
        }

        ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed).shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    func test_releasing_ClusterSystem_mustNotLeaveActorsReferringToANilSystemFromContext() async throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        var system: ClusterSystem? = await ClusterSystem("FreeMe") // only "reference from user land" to the system

        let p = self.testKit.makeTestProbe(expecting: String.self)

        let ref = try system!._spawn("echo", of: String.self, .receive { context, message in
            if message == "shutdown" {
                try! context.system.shutdown()
            }
            p.tell("system:\(context.system)")
            return .same
        })

        ref.tell("x")
        try p.expectMessage("system:ClusterSystem(FreeMe, sact://FreeMe@127.0.0.1:7337)")

        // clear the strong reference from "user land"
        system = nil

        ref.tell("x")
        try p.expectMessage("system:ClusterSystem(FreeMe, sact://FreeMe@127.0.0.1:7337)")

        ref.tell("shutdown") // since we lost the `system` reference here we'll ask the actor to stop the system

        #endif // SACT_TESTS_LEAKS
    }

    func test_actor_whichLogsShouldNotCauseLeak_onDisabledLevel() async throws {
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): disabled test

        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        let initialSystemCount = ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed)

        var system: ClusterSystem? = await ClusterSystem("Test") { settings in
            settings.logging.logLevel = .info
        }
        _ = try system?._spawn("logging", of: String.self, .setup { context in
            context.log.trace("Not going to be logged")
            return .receiveMessage { _ in .same }
        })
        try! await system?.shutdown().wait()
        system = nil

        ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed).shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    func test_actor_whichLogsShouldNotCauseLeak_onEnabled() async throws {
        #if !SACT_TESTS_LEAKS
        return self.skipLeakTests()
        #else
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): we need to manage the retain cycles with the receptionist better

        let initialSystemCount = ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed)

        var system: ClusterSystem? = await ClusterSystem("Test") { settings in
            settings.logging.logLevel = .info
        }
        _ = try system?._spawn("logging", of: String.self, .setup { context in
            context.log.warning("Not going to be logged")
            return .receiveMessage { _ in .same }
        })
        try! await system?.shutdown().wait()
        system = nil

        ClusterSystem.actorSystemInitCounter.load(ordering: .relaxed).shouldEqual(initialSystemCount)
        #endif // SACT_TESTS_LEAKS
    }

    private func skipLeakTests(function: String = #function) {
        pnote("Skipping leak test \(function), it will only be executed if -DSACT_TESTS_LEAKS is enabled.")
    }
}

extension ActorLeakingTests.LeakTestMessage: Codable {
    enum CodingKeys: CodingKey {
        case _deallocated
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Bool.self, forKey: CodingKeys._deallocated)
        self.init(UnsafeAtomic.create(value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deallocated?.load(ordering: .relaxed) ?? false, forKey: CodingKeys._deallocated)
    }
}
