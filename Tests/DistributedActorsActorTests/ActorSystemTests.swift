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

class ActorSystemTests: XCTestCase {

    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    override func tearDown() {
        try! system.terminate()
    }

    func test_spawn_shouldThrowOnDuplicateName() throws {
        let _: ActorRef<String> = try system.spawn(.ignore, name: "test")

        let error = shouldThrow {
            let _: ActorRef<String> = try system.spawn(.ignore, name: "test")
        }

        guard case let ActorContextError.duplicateActorPath(path) = error else {
            XCTFail()
            return
        }

        let expected = try ActorPath(root: "user") / ActorPathSegment("test")
        path.shouldEqual(expected)
    }

    func test_spawn_shouldNotThrowOnNameReUse() throws {
        let p: ActorTestProbe<Int> = testKit.spawnTestProbe()
        // re-using a name of an actor that has been stopped is fine
        let ref: ActorRef<String> = try system.spawn(.stopped, name: "test")

        p.watch(ref)
        try p.expectTerminated(ref)

        let _: ActorRef<String> = try system.spawn(.ignore, name: "test")
    }

    func test_terminate_shouldStopAllActors() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let echoBehavior: Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref1 = try system2.spawnAnonymous(echoBehavior)
        let ref2 = try system2.spawnAnonymous(echoBehavior)

        p.watch(ref1)
        p.watch(ref2)

        try system2.terminate()

        try p.expectTerminated(ref1)
        try p.expectTerminated(ref2)

        ref1.tell("ref1")
        ref2.tell("ref2")

        try p.expectNoMessage(for: .milliseconds(200))
    }

    func test_terminate_selfSendingActorShouldNotDeadlockSystem() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let echoBehavior: Behavior<String> = .receive { context, message in
            context.myself.tell(message)
            return .same
        }

        let selfSender = try system2.spawnAnonymous(echoBehavior)

        p.watch(selfSender)

        try system2.terminate()

        try p.expectTerminated(selfSender)
    }
}
