//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

distributed actor UnregisterOnMessage {
    var system: ActorSystem { // TODO(distributed): remove this once we have the typealias Transport support
        actorTransport._forceUnwrapActorSystem
    }

    distributed func register(with key: DistributedReception.Key<UnregisterOnMessage>) async {
        await system.receptionist.register(self, with: key)
    }
}

distributed actor StringForwarder: CustomStringConvertible {
    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, transport: ActorTransport) {
        self.probe = probe
    }

    distributed func forward(message: String) {
//    distributed func forward(message: String) -> String {
        probe.tell("forwarded:\(message)")
//        return "echo:\(message)"
    }

    nonisolated var description: String {
        "\(Self.self)(\(id.underlying))"
    }
}

extension DistributedReception.Key {
    fileprivate static var stringForwarders: DistributedReception.Key<StringForwarder> {
        "stringForwarders"
    }
}


final class OpLogDistributedReceptionistClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster/gossip",
            "/system/replicator",
            "/system/cluster",
            "/system/clusterEvents",
            "/system/cluster/leadership",
            "/system/nodeDeathWatcher",

            "/dead/system/receptionist-ref", // FIXME(distributed): it should simply be quiet
        ]
        settings.excludeGrep = [
            "timer",
        ]
    }

    let stopOnMessage: _Behavior<String> = .receive { context, _ in
        context.log.warning("Stopping...")
        return .stop
    }

    override func configureActorSystem(settings: inout ActorSystemSettings) {
        settings.cluster.receptionist.implementation = .opLogSync
        settings.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(300)

        settings.serialization.register(StringForwarder.Message.self)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sync

    func test_shouldReplicateRegistrations() throws {
        try runAsyncAndBlock {
            let (local, remote) = setUpPair()
            let testKit: ActorTestKit = self.testKit(local)
            try self.joinNodes(node: local, with: remote)

            let probe = testKit.makeTestProbe(expecting: String.self)

            // Create forwarder on 'local'
            let forwarder = StringForwarder(probe: probe, transport: local)

            // subscribe on `remote`
            let subscriberProbe = testKit.makeTestProbe("subscriber", expecting: StringForwarder.self)
            let subscriptionTask = Task {
                for try await forwarder in await remote.receptionist.subscribe(to: .stringForwarders) {
                    subscriberProbe.tell(forwarder)
                }
            }
            defer {
                subscriptionTask.cancel()
            }

            // register on `local`
            await local.receptionist.register(forwarder, with: .stringForwarders)

            try await Task {
                let found = try subscriberProbe.expectMessage()

                // we expect only one actor
                try subscriberProbe.expectNoMessage(for: .milliseconds(200))

                // check if we can interact with it
                let echo = try await found.forward(message: "test")
//                echo.shouldEqual("echo:test")
                try probe.expectMessage("forwarded:test")
            }.value
        }
    }

    func test_shouldSyncPeriodically() throws {
        try runAsyncAndBlock {
            // Don't join the nodes just yet
            let (local, remote) = setUpPair {
                $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
            }

            let probe = self.testKit(local).makeTestProbe(expecting: String.self)
            let subscriberProbe = self.testKit(local).makeTestProbe(expecting: StringForwarder.self)

            // Create on local
            let key = DistributedReception.Key(StringForwarder.self, id: "test")
            let forwarder = StringForwarder(probe: probe, transport: local)

            // Subscribe on remote
            let remoteSubscriberTask = Task {
                for try await found in await remote.receptionist.subscribe(to: key) {
                    subscriberProbe.tell(found)
                }
            }
            defer { remoteSubscriberTask.cancel() }

            // Register on local
            await local.receptionist.register(forwarder, with: key)

            // Join the nodes
            local.cluster.join(node: remote.cluster.uniqueNode.node)
            try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

            // The remote node discovers the actor
            try await Task {
                let found = try subscriberProbe.expectMessage()

                // we expect only one actor
                try subscriberProbe.expectNoMessage(for: .milliseconds(200))

                // check if we can interact with it
                let echo = try await found.forward(message: "test")
//                echo.shouldEqual("echo:test")
                try probe.expectMessage("forwarded:test")
            }.value
        }
    }

//    func test_shouldMergeEntriesOnSync() throws {
//        let (local, remote) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
//        }
//
//        let registeredProbe = self.testKit(local).makeTestProbe("registeredProbe", expecting: Reception.Registered<_ActorRef<String>>.self)
//        let localLookupProbe = self.testKit(local).makeTestProbe("localLookupProbe", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let remoteLookupProbe = self.testKit(remote).makeTestProbe("remoteLookupProbe", expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        let behavior: _Behavior<String> = .receiveMessage { _ in
//            .same
//        }
//
//        let refA: _ActorRef<String> = try local._spawn("refA", behavior)
//        let refB: _ActorRef<String> = try local._spawn("refB", behavior)
//        let refC: _ActorRef<String> = try remote._spawn("refC", behavior)
//        let refD: _ActorRef<String> = try remote._spawn("refD", behavior)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
//
//        local._receptionist.register(refA, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        local._receptionist.register(refB, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        remote._receptionist.register(refC, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        remote._receptionist.register(refD, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        local._receptionist.subscribe(localLookupProbe.ref, to: key)
//        _ = try localLookupProbe.expectMessage()
//
//        remote._receptionist.subscribe(remoteLookupProbe.ref, to: key)
//        _ = try remoteLookupProbe.expectMessage()
//
//        local.cluster.join(node: remote.cluster.uniqueNode.node)
//        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
//
//        let localListing = try localLookupProbe.expectMessage()
//        localListing.refs.count.shouldEqual(4)
//
//        let remoteListing = try remoteLookupProbe.expectMessage()
//        remoteListing.refs.count.shouldEqual(4)
//    }
//
//    // ==== ------------------------------------------------------------------------------------------------------------
//    // MARK: Remove dead actors
//
//    enum KillActorsMode {
//        case sendStop
//        case shutdownNode
//    }
//
//    func shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: KillActorsMode) throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
//        }
//
//        let registeredProbe = self.testKit(first).makeTestProbe(expecting: Reception.Registered<_ActorRef<String>>.self)
//        let remoteLookupProbe = self.testKit(second).makeTestProbe(expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        let refA: _ActorRef<String> = try first._spawn(.anonymous, self.stopOnMessage)
//        let refB: _ActorRef<String> = try first._spawn(.anonymous, self.stopOnMessage)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
//
//        first._receptionist.register(refA, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        first._receptionist.register(refB, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        second._receptionist.subscribe(remoteLookupProbe.ref, to: key)
//        _ = try remoteLookupProbe.expectMessage()
//
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
//
//        try remoteLookupProbe.eventuallyExpectListing(expected: [refA, refB], within: .seconds(3))
//
//        switch killActors {
//        case .sendStop:
//            refA.tell("stop")
//            refB.tell("stop")
//        case .shutdownNode:
//            try first.shutdown().wait()
//        }
//
//        try remoteLookupProbe.eventuallyExpectListing(expected: [], within: .seconds(3))
//    }
//
//    func test_clusterReceptionist_shouldRemoveRemoteRefs_whenTheyStop() throws {
//        try self.shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: .sendStop)
//    }
//
//    func test_clusterReceptionist_shouldRemoveRemoteRefs_whenNodeDies() throws {
//        try self.shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: .shutdownNode)
//    }
//
//    func test_clusterReceptionist_shouldRemoveRefFromAllListingsItWasRegisteredWith_ifTerminates() throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
//        }
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
//
//        let firstKey = Reception.Key(_ActorRef<String>.self, id: "first")
//        let extraKey = Reception.Key(_ActorRef<String>.self, id: "extra")
//
//        let ref = try first._spawn("hi", self.stopOnMessage)
//        first._receptionist.register(ref, with: firstKey)
//        first._receptionist.register(ref, with: extraKey)
//
//        let p1f = self.testKit(first).makeTestProbe("p1f", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p1e = self.testKit(first).makeTestProbe("p1e", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p2f = self.testKit(second).makeTestProbe("p2f", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p2e = self.testKit(second).makeTestProbe("p2e", expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        // ensure the ref is registered and known under both keys to both nodes
//        first._receptionist.subscribe(p1f.ref, to: firstKey)
//        first._receptionist.subscribe(p1e.ref, to: extraKey)
//
//        second._receptionist.subscribe(p2f.ref, to: firstKey)
//        second._receptionist.subscribe(p2e.ref, to: extraKey)
//
//        func expectListingOnAllProbes(expected: Set<_ActorRef<String>>) throws {
//            try p1f.eventuallyExpectListing(expected: expected, within: .seconds(3))
//            try p1e.eventuallyExpectListing(expected: expected, within: .seconds(3))
//
//            try p2f.eventuallyExpectListing(expected: expected, within: .seconds(3))
//            try p2e.eventuallyExpectListing(expected: expected, within: .seconds(3))
//        }
//
//        try expectListingOnAllProbes(expected: [ref])
//
//        // terminate it
//        ref.tell("stop!")
//
//        // it should be removed from all listings; on both nodes, for all keys
//        try expectListingOnAllProbes(expected: [])
//    }
//
//    func test_clusterReceptionist_shouldRemoveActorsOfTerminatedNodeFromListings_onNodeCrash() throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
//        }
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "key")
//
//        let firstRef = try first._spawn("onFirst", self.stopOnMessage)
//        first._receptionist.register(firstRef, with: key)
//
//        let secondRef = try second._spawn("onSecond", self.stopOnMessage)
//        second._receptionist.register(secondRef, with: key)
//
//        let p1 = self.testKit(first).makeTestProbe("p1", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p2 = self.testKit(second).makeTestProbe("p2", expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        // ensure the ref is registered and known under both keys to both nodes
//        first._receptionist.subscribe(p1.ref, to: key)
//        second._receptionist.subscribe(p2.ref, to: key)
//
//        try p1.eventuallyExpectListing(expected: [firstRef, secondRef], within: .seconds(3))
//        try p2.eventuallyExpectListing(expected: [firstRef, secondRef], within: .seconds(3))
//
//        // crash the second node
//        try second.shutdown().wait()
//
//        // it should be removed from all listings; on both nodes, for all keys
//        try p1.eventuallyExpectListing(expected: [firstRef], within: .seconds(5))
//    }
//
//    func test_clusterReceptionist_shouldRemoveManyRemoteActorsFromListingInBulk() throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
//        }
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "key")
//
//        let firstRef = try first._spawn("onFirst", self.stopOnMessage)
//        first._receptionist.register(firstRef, with: key)
//
//        let remotes: [_ActorRef<String>] = try (1 ... 100).map {
//            let ref = try second._spawn("remote-\($0)", self.stopOnMessage)
//            second._receptionist.register(ref, with: key)
//            return ref
//        }
//
//        let p1 = self.testKit(first).makeTestProbe("p1", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p2 = self.testKit(second).makeTestProbe("p2", expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        // ensure the ref is registered and known under both keys to both nodes
//        first._receptionist.subscribe(p1.ref, to: key)
//        second._receptionist.subscribe(p2.ref, to: key)
//
//        var allRefs = Set(remotes)
//        allRefs.insert(firstRef)
//        try p1.eventuallyExpectListing(expected: allRefs, within: .seconds(5))
//        try p2.eventuallyExpectListing(expected: allRefs, within: .seconds(5))
//
//        // crash the second node
//        try second.shutdown().wait()
//
//        // it should be removed from all listings; on both nodes, for all keys
//        try p1.eventuallyExpectListing(expected: [firstRef], within: .seconds(5), verbose: true)
//    }
//
//    // ==== ------------------------------------------------------------------------------------------------------------
//    // MARK: Multi node / streaming
//
//    func test_clusterReceptionist_shouldStreamAllRegisteredActorsInChunks() throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
//        }
//        first.cluster.join(node: second.cluster.uniqueNode.node)
//        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "first")
//
//        var allRefs: Set<_ActorRef<String>> = []
//        for i in 1 ... (first.settings.cluster.receptionist.syncBatchSize * 10) {
//            let ref = try first._spawn("example-\(i)", self.stopOnMessage)
//            first._receptionist.register(ref, with: key)
//            _ = allRefs.insert(ref)
//        }
//
//        let p1 = self.testKit(first).makeTestProbe("p1", expecting: Reception.Listing<_ActorRef<String>>.self)
//        let p2 = self.testKit(second).makeTestProbe("p2", expecting: Reception.Listing<_ActorRef<String>>.self)
//
//        // ensure the ref is registered and known under both keys to both nodes
//        first._receptionist.subscribe(p1.ref, to: key)
//        second._receptionist.subscribe(p2.ref, to: key)
//
//        try p1.eventuallyExpectListing(expected: allRefs, within: .seconds(10))
//        try p2.eventuallyExpectListing(expected: allRefs, within: .seconds(10))
//    }
//
//    func test_clusterReceptionist_shouldSpreadInformationAmongManyNodes() throws {
//        let (first, second) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
//        }
//        let third = setUpNode("third")
//        let fourth = setUpNode("fourth")
//
//        try self.joinNodes(node: first, with: second)
//        try self.joinNodes(node: first, with: third)
//        try self.joinNodes(node: fourth, with: second)
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "key")
//
//        let ref = try first._spawn("hi", self.stopOnMessage)
//        first._receptionist.register(ref, with: key)
//
//        func expectListingContainsRef(on system: ActorSystem) throws {
//            let p = self.testKit(system).makeTestProbe("p", expecting: Reception.Listing<_ActorRef<String>>.self)
//            system._receptionist.subscribe(p.ref, to: key)
//
//            try p.eventuallyExpectListing(expected: [ref], within: .seconds(3))
//        }
//
//        try expectListingContainsRef(on: first)
//        try expectListingContainsRef(on: second)
//        try expectListingContainsRef(on: third)
//        try expectListingContainsRef(on: fourth)
//    }
}
