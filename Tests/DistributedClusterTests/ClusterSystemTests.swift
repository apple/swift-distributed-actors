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

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ClusterSystemTests {
    let MaxSpecialTreatedValueTypeSizeInBytes = 24

    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    @Test
    func test_system_spawn_shouldThrowOnDuplicateName() throws {
        let _: _ActorRef<String> = try self.testCase.system._spawn("test", .ignore)

        let error = try shouldThrow {
            let _: _ActorRef<String> = try self.testCase.system._spawn("test", .ignore)
        }

        guard let systemError = error as? ClusterSystemError, case .duplicateActorPath(let path, _) = systemError.underlying.error else {
            Issue.record("Expected ClusterSystemError.duplicateActorPath, but was: \(error)")
            return
        }

        let expected = try ActorPath(root: "user") / ActorPathSegment("test")
        path.shouldEqual(expected)
    }

    @Test
    func test_system_spawn_shouldNotThrowOnNameReUse() throws {
        let p: ActorTestProbe<Int> = self.testCase.testKit.makeTestProbe()
        // re-using a name of an actor that has been stopped is fine
        let ref: _ActorRef<String> = try self.testCase.system._spawn("test", .stop)

        p.watch(ref)
        try p.expectTerminated(ref)

        // since spawning on top level is racy for the names replacements;
        // we try a few times, and if it eventually succeeds things are correct -- it should succeed only once though
        try self.testCase.testKit.eventually(within: .milliseconds(500)) {
            let _: _ActorRef<String> = try self.testCase.system._spawn("test", .ignore)
        }
    }

    @Test
    func test_shutdown_shouldStopAllActors() async throws {
        let system2 = await ClusterSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testCase.testKit.makeTestProbe()
        let echoBehavior: _Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref1 = try system2._spawn(.anonymous, echoBehavior)
        let ref2 = try system2._spawn(.anonymous, echoBehavior)

        p.watch(ref1)
        p.watch(ref2)

        try await system2.shutdown().wait()

        try p.expectTerminatedInAnyOrder([ref1.asAddressable, ref2.asAddressable])

        ref1.tell("ref1")
        ref2.tell("ref2")

        try p.expectNoMessage(for: .milliseconds(200))
    }

    @Test
    func test_shutdown_shouldCompleteReturnedHandleWhenDone() async throws {
        let shutdown = try self.testCase.system.shutdown()
        try shutdown.wait(atMost: .seconds(5))
    }

    @Test(.disabled("Needs to be re-enabled"))
    func test_shutdown_shouldReUseReceptacleWhenCalledMultipleTimes() async throws {
        let system2 = await ClusterSystem("ShutdownSystem")
        let shutdown1 = try system2.shutdown()
        let shutdown2 = try system2.shutdown()
        let shutdown3 = try system2.shutdown()

        try shutdown1.wait(atMost: .seconds(5))
        try shutdown2.wait(atMost: .milliseconds(1))
        try shutdown3.wait(atMost: .milliseconds(1))
    }

    @Test
    func test_shutdown_selfSendingActorShouldNotDeadlockSystem() async throws {
        let system2 = await ClusterSystem("ShutdownSystem")
        let p: ActorTestProbe<String> = self.testCase.testKit.makeTestProbe()
        let echoBehavior: _Behavior<String> = .receive { context, message in
            context.myself.tell(message)
            return .same
        }

        let selfSender = try system2._spawn(.anonymous, echoBehavior)

        p.watch(selfSender)

        try await system2.shutdown().wait()

        try p.expectTerminated(selfSender)
    }

    @Test
    func test_terminated_triggerOnceSystemIsShutdown() async throws {
        let system2 = await ClusterSystem("ShutdownSystem") {
            $0.enabled = false // no clustering
        }

        Task.detached {
            try system2.shutdown()
        }

        try await system2.terminated // should be terminated after shutdown()
    }

    @Test
    func test_shutdownWait_triggerOnceSystemIsShutdown() async throws {
        let system2 = await ClusterSystem("ShutdownSystem") {
            $0.enabled = false // no clustering
        }

        try await system2.shutdown().wait()
    }

    @Test
    func test_resolveUnknownActor_shouldReturnPersonalDeadLetters() throws {
        let path = try ActorPath._user.appending("test").appending("foo").appending("bar")
        let id = ActorID(local: self.testCase.system.cluster.node, path: path, incarnation: .random())
        let context: _ResolveContext<Never> = _ResolveContext(id: id, system: self.testCase.system)
        let ref = self.testCase.system._resolve(context: context)

        ref.id.path.shouldEqual(ActorPath._dead.appending(segments: path.segments))
        ref.id.incarnation.shouldEqual(id.incarnation)
    }

    @Test
    func test_cleanUpAssociationTombstones() async throws {
        let local = await self.testCase.setUpNode("local") { settings in
            settings.enabled = true
            settings.associationTombstoneTTL = .seconds(0)
        }
        let remote = await self.testCase.setUpNode("remote") { settings in
            settings.enabled = true
        }
        local.cluster.join(endpoint: remote.cluster.endpoint)

        let remoteAssociationControlState0 = local._cluster!.getEnsureAssociation(with: remote.cluster.node)
        guard case ClusterShell.StoredAssociationState.association(let remoteControl0) = remoteAssociationControlState0 else {
            throw Boom("Expected the association to exist for \(remote.cluster.node)")
        }

        ClusterShell.shootTheOtherNodeAndCloseConnection(system: local, targetNodeAssociation: remoteControl0)

        // Endpoint should eventually appear in tombstones
        try self.testCase.testKit(local).eventually(within: .seconds(3)) {
            guard local._cluster?._testingOnly_associationTombstones.isEmpty == false else {
                throw Boom("Expected tombstone for downed node")
            }
        }

        local._cluster?.ref.tell(.command(.cleanUpAssociationTombstones))

        try self.testCase.testKit(local).eventually(within: .seconds(3)) {
            guard local._cluster?._testingOnly_associationTombstones.isEmpty == true else {
                throw Boom("Expected tombstones to get cleared")
            }
        }
    }
}
