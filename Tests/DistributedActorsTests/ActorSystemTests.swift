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
import DistributedActorsTestKit
import Foundation
import XCTest

class ActorSystemTests: XCTestCase {
    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_system_spawn_shouldThrowOnDuplicateName() throws {
        let _: ActorRef<String> = try system.spawn("test", .ignore)

        let error = shouldThrow {
            let _: ActorRef<String> = try system.spawn("test", .ignore)
        }

        guard case ActorContextError.duplicateActorPath(let path) = error else {
            XCTFail()
            return
        }

        let expected = try ActorPath(root: "user") / ActorPathSegment("test")
        path.shouldEqual(expected)
    }

    func test_system_spawn_shouldNotThrowOnNameReUse() throws {
        let p: ActorTestProbe<Int> = self.testKit.spawnTestProbe()
        // re-using a name of an actor that has been stopped is fine
        let ref: ActorRef<String> = try system.spawn("test", .stop)

        p.watch(ref)
        try p.expectTerminated(ref)

        // since spawning on top level is racy for the names replacements;
        // we try a few times, and if it eventually succeeds things are correct -- it should succeed only once though
        try self.testKit.eventually(within: .milliseconds(500)) {
            let _: ActorRef<String> = try system.spawn("test", .ignore)
        }
    }

    func test_shutdown_shouldStopAllActors() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let echoBehavior: Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref1 = try system2.spawn(.anonymous, echoBehavior)
        let ref2 = try system2.spawn(.anonymous, echoBehavior)

        p.watch(ref1)
        p.watch(ref2)

        system2.shutdown().wait()

        try p.expectTerminatedInAnyOrder([ref1.asAddressable(), ref2.asAddressable()])

        ref1.tell("ref1")
        ref2.tell("ref2")

        try p.expectNoMessage(for: .milliseconds(200))
    }

    func test_shutdown_shouldCompleteReturnedHandleWhenDone() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let shutdown = system2.shutdown()
        try shutdown.wait(atMost: .seconds(5))
    }

    func test_shutdown_shouldReUseReceptacleWhenCalledMultipleTimes() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let shutdown1 = system2.shutdown()
        let shutdown2 = system2.shutdown()
        let shutdown3 = system2.shutdown()

        try shutdown1.wait(atMost: .seconds(5))
        try shutdown2.wait(atMost: .milliseconds(1))
        try shutdown3.wait(atMost: .milliseconds(1))
    }

    func test_shutdown_selfSendingActorShouldNotDeadlockSystem() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let echoBehavior: Behavior<String> = .receive { context, message in
            context.myself.tell(message)
            return .same
        }

        let selfSender = try system2.spawn(.anonymous, echoBehavior)

        p.watch(selfSender)

        system2.shutdown().wait()

        try p.expectTerminated(selfSender)
    }
}
