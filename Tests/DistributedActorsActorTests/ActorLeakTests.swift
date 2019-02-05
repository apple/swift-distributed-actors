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
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class ActorLeakingTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }

    // MARK: starting actors

    struct NotEnoughActorsAlive: Error {
        let expected: Int
        let current: Int
    }
    struct TooManyActorsAlive: Error {
        let expected: Int
        let current: Int
    }

    func test_spawn_stop_shouldNotLeakActors() throws {
        #if SACT_TESTS_LEAKS

        let stopsOnAnyMessage: Behavior<String> = .receiveMessage { msg in
            return .stopped
        }

        var ref: ActorRef<String>? = try system.spawn(stopsOnAnyMessage, name: "printer")

        let afterStartActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.cellInitCounter.load()
            if counter != 1 {
                throw NotEnoughActorsAlive(expected: 1, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell("please stop")
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) {() -> Int in
            let counter = self.system.cellInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartActorCount.shouldEqual(1)
        afterStopActorCount.shouldEqual(0)

        #else
        pnote("Skipping leak test \(#function), it will only be executed if -DSACT_TESTS_LEAKS is enabled.")
        return ()
        #endif
    }

    func test_parentWithChildrenStopping_shouldNotLeakActors() throws {
        #if SACT_TESTS_LEAKS

        let spawnsNChildren: Behavior<Int> = .receive { context, childCount in
            if childCount == 0 {
                return .stopped
            } else {
                for _ in 1...childCount {
                    let b: Behavior<String> = .receiveMessage { msg in return .same }
                    try context.spawnAnonymous(b)
                }
                return .same
            }
        }

        var ref: ActorRef<Int>? = try system.spawn(spawnsNChildren, name: "printer")

        let expectedParentCount = 1
        let expectedChildrenCount = 3
        let expectedActorCount = expectedParentCount + expectedChildrenCount

        ref?.tell(expectedChildrenCount)

        let afterStartActorCount = try testKit.eventually(within: .milliseconds(200)) { () -> Int in
            let counter = self.system.cellInitCounter.load()
            if counter != expectedActorCount {
                throw NotEnoughActorsAlive(expected: expectedActorCount, current: counter)
            } else {
                return counter
            }
        }

        ref?.tell(0) // stops the parent actor
        ref = nil

        let afterStopActorCount = try testKit.eventually(within: .milliseconds(200)) {() -> Int in
            let counter = self.system.cellInitCounter.load()
            if counter != 0 {
                throw TooManyActorsAlive(expected: 0, current: counter)
            } else {
                return counter
            }
        }

        afterStartActorCount.shouldEqual(expectedActorCount)
        afterStopActorCount.shouldEqual(0)

        #else
        pnote("Skipping leak test \(#function), it will only be executed if -DSACT_TESTS_LEAKS is enabled.")
        return ()
        #endif
    }

}
