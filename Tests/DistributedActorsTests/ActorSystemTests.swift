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

final class ActorSystemTests: ActorSystemXCTestCase {
    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    func test_system_spawn_shouldThrowOnDuplicateName() throws {
        let _: _ActorRef<String> = try system._spawn("test", .ignore)

        let error = try shouldThrow {
            let _: _ActorRef<String> = try system._spawn("test", .ignore)
        }

        guard case ActorSystemError.duplicateActorPath(let path) = error else {
            XCTFail("Expected ActorSystemError.duplicateActorPath, but was: \(error)")
            return
        }

        let expected = try ActorPath(root: "user") / ActorPathSegment("test")
        path.shouldEqual(expected)
    }

    func test_system_spawn_shouldNotThrowOnNameReUse() throws {
        let p: ActorTestProbe<Int> = self.testKit.makeTestProbe()
        // re-using a name of an actor that has been stopped is fine
        let ref: _ActorRef<String> = try system._spawn("test", .stop)

        p.watch(ref)
        try p.expectTerminated(ref)

        // since spawning on top level is racy for the names replacements;
        // we try a few times, and if it eventually succeeds things are correct -- it should succeed only once though
        try self.testKit.eventually(within: .milliseconds(500)) {
            let _: _ActorRef<String> = try system._spawn("test", .ignore)
        }
    }

    func test_shutdown_shouldStopAllActors() async throws {
        let system2 = await ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let echoBehavior: _Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref1 = try system2._spawn(.anonymous, echoBehavior)
        let ref2 = try system2._spawn(.anonymous, echoBehavior)

        p.watch(ref1)
        p.watch(ref2)

        try system2.shutdown().wait()

        try p.expectTerminatedInAnyOrder([ref1.asAddressable, ref2.asAddressable])

        ref1.tell("ref1")
        ref2.tell("ref2")

        try p.expectNoMessage(for: .milliseconds(200))
    }

    func test_shutdown_shouldCompleteReturnedHandleWhenDone() throws {
        let system2 = await ActorSystem("ShutdownSystem")
        let shutdown = system2.shutdown()
        try shutdown.wait(atMost: .seconds(5))
    }

    func test_shutdown_shouldReUseReceptacleWhenCalledMultipleTimes() async throws {
        throw XCTSkip("Needs to be re-enabled") // FIXME: re-enable this test
        let system2 = await ActorSystem("ShutdownSystem")
        let shutdown1 = system2.shutdown()
        let shutdown2 = system2.shutdown()
        let shutdown3 = system2.shutdown()

        try shutdown1.wait(atMost: .seconds(5))
        try shutdown2.wait(atMost: .milliseconds(1))
        try shutdown3.wait(atMost: .milliseconds(1))
    }

    func test_shutdown_selfSendingActorShouldNotDeadlockSystem() throws {
        let system2 = ActorSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let echoBehavior: _Behavior<String> = .receive { context, message in
            context.myself.tell(message)
            return .same
        }

        let selfSender = try system2._spawn(.anonymous, echoBehavior)

        p.watch(selfSender)

        try system2.shutdown().wait()

        try p.expectTerminated(selfSender)
    }

    func test_resolveUnknownActor_shouldReturnPersonalDeadLetters() throws {
        let path = try ActorPath._user.appending("test").appending("foo").appending("bar")
        let address = ActorAddress(local: self.system.cluster.uniqueNode, path: path, incarnation: .random())
        let context: ResolveContext<Never> = ResolveContext(address: address, system: self.system)
        let ref = self.system._resolve(context: context)

        ref.address.path.shouldEqual(ActorPath._dead.appending(segments: path.segments))
        ref.address.incarnation.shouldEqual(address.incarnation)
    }

    func test_shutdown_callbackShouldBeInvoked() async throws {
        let system = await ActorSystem("ShutMeDown")
        let receptacle = BlockingReceptacle<Error?>()

        system.shutdown(afterShutdownCompleted: { error in
            receptacle.offerOnce(error)
        })

        receptacle.wait(atMost: .seconds(3))!.shouldBeNil()
    }

    func test_shutdown_callbackShouldBeInvokedWhenAlreadyShutdown() async throws {
        let system = await ActorSystem("ShutMeDown")
        let firstReceptacle = BlockingReceptacle<Error?>()

        system.shutdown(afterShutdownCompleted: { error in
            firstReceptacle.offerOnce(error)
        })

        firstReceptacle.wait(atMost: .seconds(3))!.shouldBeNil()

        let secondReceptacle = BlockingReceptacle<Error?>()

        system.shutdown(afterShutdownCompleted: { error in
            secondReceptacle.offerOnce(error)
        })

        secondReceptacle.wait(atMost: .seconds(3))!.shouldBeNil()
    }
}
