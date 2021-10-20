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
        defer { transport.actorReady(self) }
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

    let stopOnMessage: Behavior<String> = .receive { context, _ in
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

            let probe = testKit.spawnTestProbe(expecting: String.self)

            // Create forwarder on 'local'
            let forwarder = StringForwarder(probe: probe, transport: local)

            // subscribe on `remote`
            let subscriberProbe = testKit.spawnTestProbe("subscriber", expecting: StringForwarder.self)
            let subscriptionTask = Task.detached {
                pprint("START SUBscription")
                try await Task.withCancellationHandler(handler: { pnote("CANCELLED") }) {
                    for try await forwarder in await remote.receptionist.subscribe(to: .stringForwarders) {
                        subscriberProbe.tell(forwarder)
                        pprint("SENT: \(forwarder) >> \(subscriberProbe)")
                    }
                    pprint("ENDED SUBscription")
                }
            }
            defer {
                subscriptionTask.cancel()
            }

            // register on `local`
            pprint(" >>> REGISTER")
            await local.receptionist.register(forwarder, with: .stringForwarders)
            pprint(" >>> REGISTER OK")

                pprint(" >>> EXPECT REGISTERED REF")
                let registeredRef = try subscriberProbe.expectMessage()
                pprint(" >>> EXPECT REGISTERED REF - OK")

                // we expect only one actor
                pprint(" >>> EXPECT NO")
                try subscriberProbe.expectNoMessage(for: .milliseconds(200))

                // check if we can interact with it
                let echo = try await registeredRef.forward(message: "test")
//                echo.shouldEqual("echo:test")
                try probe.expectMessage("forwarded:test")

        }
    }

//    func test_shouldSyncPeriodically() throws {
//        let (local, remote) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
//        }
//
//        let probe = self.testKit(local).spawnTestProbe(expecting: String.self)
//        let registeredProbe = self.testKit(local).spawnTestProbe(expecting: Reception.Registered<ActorRef<String>>.self)
//        let lookupProbe = self.testKit(local).spawnTestProbe(expecting: Reception.Listing<ActorRef<String>>.self)
//
//        let ref: ActorRef<String> = try local.spawn(
//            .anonymous,
//            .receiveMessage {
//                probe.tell("received:\($0)")
//                return .same
//            }
//        )
//
//        let key = Reception.Key(ActorRef<String>.self, id: "test")
//
//        remote._receptionist.subscribe(lookupProbe.ref, to: key)
//
//        _ = try lookupProbe.expectMessage()
//
//        local._receptionist.register(ref, with: key, replyTo: registeredProbe.ref)
//        _ = try registeredProbe.expectMessage()
//
//        local.cluster.join(node: remote.cluster.uniqueNode.node)
//        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
//
//        let listing = try lookupProbe.expectMessage()
//        listing.refs.count.shouldEqual(1)
//        guard let registeredRef = listing.refs.first else {
//            throw lookupProbe.error("listing contained no entries, expected 1")
//        }
//        registeredRef.tell("test")
//
//        try probe.expectMessage("received:test")
//    }
//
//    func test_shouldMergeEntriesOnSync() throws {
//        let (local, remote) = setUpPair {
//            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
//        }
//
//        let registeredProbe = self.testKit(local).spawnTestProbe("registeredProbe", expecting: Reception.Registered<ActorRef<String>>.self)
//        let localLookupProbe = self.testKit(local).spawnTestProbe("localLookupProbe", expecting: Reception.Listing<ActorRef<String>>.self)
//        let remoteLookupProbe = self.testKit(remote).spawnTestProbe("remoteLookupProbe", expecting: Reception.Listing<ActorRef<String>>.self)
//
//        let behavior: Behavior<String> = .receiveMessage { _ in
//            .same
//        }
//
//        let refA: ActorRef<String> = try local.spawn("refA", behavior)
//        let refB: ActorRef<String> = try local.spawn("refB", behavior)
//        let refC: ActorRef<String> = try remote.spawn("refC", behavior)
//        let refD: ActorRef<String> = try remote.spawn("refD", behavior)
//
//        let key = Reception.Key(ActorRef<String>.self, id: "test")
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
//        let registeredProbe = self.testKit(first).spawnTestProbe(expecting: Reception.Registered<ActorRef<String>>.self)
//        let remoteLookupProbe = self.testKit(second).spawnTestProbe(expecting: Reception.Listing<ActorRef<String>>.self)
//
//        let refA: ActorRef<String> = try first.spawn(.anonymous, self.stopOnMessage)
//        let refB: ActorRef<String> = try first.spawn(.anonymous, self.stopOnMessage)
//
//        let key = Reception.Key(ActorRef<String>.self, id: "test")
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
//        let firstKey = Reception.Key(ActorRef<String>.self, id: "first")
//        let extraKey = Reception.Key(ActorRef<String>.self, id: "extra")
//
//        let ref = try first.spawn("hi", self.stopOnMessage)
//        first._receptionist.register(ref, with: firstKey)
//        first._receptionist.register(ref, with: extraKey)
//
//        let p1f = self.testKit(first).spawnTestProbe("p1f", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p1e = self.testKit(first).spawnTestProbe("p1e", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p2f = self.testKit(second).spawnTestProbe("p2f", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p2e = self.testKit(second).spawnTestProbe("p2e", expecting: Reception.Listing<ActorRef<String>>.self)
//
//        // ensure the ref is registered and known under both keys to both nodes
//        first._receptionist.subscribe(p1f.ref, to: firstKey)
//        first._receptionist.subscribe(p1e.ref, to: extraKey)
//
//        second._receptionist.subscribe(p2f.ref, to: firstKey)
//        second._receptionist.subscribe(p2e.ref, to: extraKey)
//
//        func expectListingOnAllProbes(expected: Set<ActorRef<String>>) throws {
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
//        let key = Reception.Key(ActorRef<String>.self, id: "key")
//
//        let firstRef = try first.spawn("onFirst", self.stopOnMessage)
//        first._receptionist.register(firstRef, with: key)
//
//        let secondRef = try second.spawn("onSecond", self.stopOnMessage)
//        second._receptionist.register(secondRef, with: key)
//
//        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Reception.Listing<ActorRef<String>>.self)
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
//        let key = Reception.Key(ActorRef<String>.self, id: "key")
//
//        let firstRef = try first.spawn("onFirst", self.stopOnMessage)
//        first._receptionist.register(firstRef, with: key)
//
//        let remotes: [ActorRef<String>] = try (1 ... 100).map {
//            let ref = try second.spawn("remote-\($0)", self.stopOnMessage)
//            second._receptionist.register(ref, with: key)
//            return ref
//        }
//
//        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Reception.Listing<ActorRef<String>>.self)
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
//        let key = Reception.Key(ActorRef<String>.self, id: "first")
//
//        var allRefs: Set<ActorRef<String>> = []
//        for i in 1 ... (first.settings.cluster.receptionist.syncBatchSize * 10) {
//            let ref = try first.spawn("example-\(i)", self.stopOnMessage)
//            first._receptionist.register(ref, with: key)
//            _ = allRefs.insert(ref)
//        }
//
//        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Reception.Listing<ActorRef<String>>.self)
//        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Reception.Listing<ActorRef<String>>.self)
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
//        let key = Reception.Key(ActorRef<String>.self, id: "key")
//
//        let ref = try first.spawn("hi", self.stopOnMessage)
//        first._receptionist.register(ref, with: key)
//
//        func expectListingContainsRef(on system: ActorSystem) throws {
//            let p = self.testKit(system).spawnTestProbe("p", expecting: Reception.Listing<ActorRef<String>>.self)
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
