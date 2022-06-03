//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class ClusterSystemTests: ActorSystemXCTestCase {
    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    func test_system_spawn_shouldThrowOnDuplicateName() throws {
        let _: _ActorRef<String> = try system._spawn("test", .ignore)

        let error = try shouldThrow {
            let _: _ActorRef<String> = try system._spawn("test", .ignore)
        }

        guard case ClusterSystemError.duplicateActorPath(let path) = error else {
            XCTFail("Expected ClusterSystemError.duplicateActorPath, but was: \(error)")
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
        let system2 = await ClusterSystem("ShutdownSystem")
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

    func test_shutdown_shouldCompleteReturnedHandleWhenDone() async throws {
        let system2 = await ClusterSystem("ShutdownSystem")
        let shutdown = system2.shutdown()
        try shutdown.wait(atMost: .seconds(5))
    }

    func test_shutdown_shouldReUseReceptacleWhenCalledMultipleTimes() async throws {
        throw XCTSkip("Needs to be re-enabled") // FIXME: re-enable this test
        let system2 = await ClusterSystem("ShutdownSystem")
        let shutdown1 = system2.shutdown()
        let shutdown2 = system2.shutdown()
        let shutdown3 = system2.shutdown()

        try shutdown1.wait(atMost: .seconds(5))
        try shutdown2.wait(atMost: .milliseconds(1))
        try shutdown3.wait(atMost: .milliseconds(1))
    }

    func test_shutdown_selfSendingActorShouldNotDeadlockSystem() async throws {
        let system2 = await ClusterSystem("ShutdownSystem")
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
        throw XCTSkip("Pending revival of offline mode?") // FIXME(offline): issues with binding system again

        let system = await ClusterSystem("ShutMeDown") { settings in
            settings.bindPort = 9877
        }
        let receptacle = BlockingReceptacle<Error?>()

        system.shutdown(afterShutdownCompleted: { error in
            receptacle.offerOnce(error)
        })

        receptacle.wait(atMost: .seconds(3))!.shouldBeNil()
    }

    func test_shutdown_callbackShouldBeInvokedWhenAlreadyShutdown() async throws {
        let system = await ClusterSystem("ShutMeDown")
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

    func test_remoteCall_shouldConfigureTimeout() async throws {
        let local = await setUpNode("local")
        let remote = await setUpNode("remote")
        local.cluster.join(node: remote.cluster.uniqueNode)

        let greeter = DelayedGreeter(actorSystem: local)
        let remoteGreeter = try DelayedGreeter.resolve(id: greeter.id, using: remote)

        let error = try await shouldThrow {
            try await RemoteCall.with(timeout: .seconds(1)) {
                _ = try await remoteGreeter.hello()
            }
        }

        guard case RemoteCallError.timedOut(let timeoutError) = error else {
            throw testKit.fail("Expected RemoteCallError.timedOut, got \(error)")
        }
        guard timeoutError.timeout == .seconds(1) else {
            throw testKit.fail("Expected timeout to be 1 second but was \(timeoutError.timeout)")
        }
    }

    func test_cleanUpAssociationTombstones() async throws {
        let local = await setUpNode("local") {
            $0.associationTombstoneTTL = .seconds(0)
        }
        let remote = await setUpNode("remote")
        local.cluster.join(node: remote.cluster.uniqueNode)

        let remoteAssociationControlState0 = local._cluster!.getEnsureAssociation(with: remote.cluster.uniqueNode)
        guard case ClusterShell.StoredAssociationState.association(let remoteControl0) = remoteAssociationControlState0 else {
            throw Boom("Expected the association to exist for \(remote.cluster.uniqueNode)")
        }

        ClusterShell.shootTheOtherNodeAndCloseConnection(system: local, targetNodeAssociation: remoteControl0)

        // Node should eventually appear in tombstones
        try self.testKit(local).eventually(within: .seconds(3)) {
            guard local._cluster?._testingOnly_associationTombstones.isEmpty == false else {
                throw Boom("Expected tombstone for downed node")
            }
        }

        local._cluster?.ref.tell(.command(.cleanUpAssociationTombstones))

        try self.testKit(local).eventually(within: .seconds(3)) {
            guard local._cluster?._testingOnly_associationTombstones.isEmpty == true else {
                throw Boom("Expected tombstones to get cleared")
            }
        }
    }
}

private distributed actor DelayedGreeter {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem

    distributed func hello() async throws -> String {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return "hello"
    }
}
