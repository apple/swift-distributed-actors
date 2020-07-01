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

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class OpLogClusterReceptionistClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster/gossip",
            "/system/replicator",
            "/system/cluster",
            "/system/clusterEvents",
            "/system/cluster/leadership",
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
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sync

    func test_shouldReplicateRegistrations() throws {
        let (local, remote) = setUpPair()
        let testKit: ActorTestKit = self.testKit(local)
        try self.joinNodes(node: local, with: remote)

        let probe = testKit.spawnTestProbe(expecting: String.self)
        let registeredProbe = testKit.spawnTestProbe("registered", expecting: Receptionist.Registered<ActorRef<String>>.self)

        let ref: ActorRef<String> = try local.spawn(
            .anonymous,
            .receiveMessage {
                probe.tell("received:\($0)")
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "test")

        // subscribe on `remote`
        let subscriberProbe = testKit.spawnTestProbe(expecting: Receptionist.Listing<ActorRef<String>>.self)
        remote.receptionist.subscribe(key: key, subscriber: subscriberProbe.ref)
        _ = try subscriberProbe.expectMessage()

        // register on `local`
        local.receptionist.register(ref, key: key, replyTo: registeredProbe.ref)
        _ = try registeredProbe.expectMessage()

        let listing = try subscriberProbe.expectMessage()
        listing.refs.count.shouldEqual(1)
        guard let registeredRef = listing.refs.first else {
            throw subscriberProbe.error("listing contained no entries, expected 1")
        }
        registeredRef.tell("test")

        try probe.expectMessage("received:test")
    }

    func test_shouldSyncPeriodically() throws {
        let (local, remote) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
        }

        let probe = self.testKit(local).spawnTestProbe(expecting: String.self)
        let registeredProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Registered<ActorRef<String>>.self)
        let lookupProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Listing<ActorRef<String>>.self)

        let ref: ActorRef<String> = try local.spawn(
            .anonymous,
            .receiveMessage {
                probe.tell("received:\($0)")
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "test")

        remote.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: lookupProbe.ref))

        _ = try lookupProbe.expectMessage()

        local.receptionist.tell(Receptionist.Register(ref, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let listing = try lookupProbe.expectMessage()
        listing.refs.count.shouldEqual(1)
        guard let registeredRef = listing.refs.first else {
            throw lookupProbe.error("listing contained no entries, expected 1")
        }
        registeredRef.tell("test")

        try probe.expectMessage("received:test")
    }

    func test_shouldMergeEntriesOnSync() throws {
        let (local, remote) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
        }

        let registeredProbe = self.testKit(local).spawnTestProbe("registeredProbe", expecting: Receptionist.Registered<ActorRef<String>>.self)
        let localLookupProbe = self.testKit(local).spawnTestProbe("localLookupProbe", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let remoteLookupProbe = self.testKit(remote).spawnTestProbe("remoteLookupProbe", expecting: Receptionist.Listing<ActorRef<String>>.self)

        let behavior: Behavior<String> = .receiveMessage { _ in
            .same
        }

        let refA: ActorRef<String> = try local.spawn("refA", behavior)
        let refB: ActorRef<String> = try local.spawn("refB", behavior)
        let refC: ActorRef<String> = try remote.spawn("refC", behavior)
        let refD: ActorRef<String> = try remote.spawn("refD", behavior)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "test")

        local.receptionist.tell(Receptionist.Register(refA, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        local.receptionist.tell(Receptionist.Register(refB, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        remote.receptionist.tell(Receptionist.Register(refC, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        remote.receptionist.tell(Receptionist.Register(refD, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        local.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: localLookupProbe.ref))
        _ = try localLookupProbe.expectMessage()

        remote.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: remoteLookupProbe.ref))
        _ = try remoteLookupProbe.expectMessage()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let localListing = try localLookupProbe.expectMessage()
        localListing.refs.count.shouldEqual(4)

        let remoteListing = try remoteLookupProbe.expectMessage()
        remoteListing.refs.count.shouldEqual(4)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Remove dead actors

    enum KillActorsMode {
        case sendStop
        case shutdownNode
    }

    func shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: KillActorsMode) throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .seconds(1)
        }

        let registeredProbe = self.testKit(first).spawnTestProbe(expecting: Receptionist.Registered<ActorRef<String>>.self)
        let remoteLookupProbe = self.testKit(second).spawnTestProbe(expecting: Receptionist.Listing<ActorRef<String>>.self)

        let refA: ActorRef<String> = try first.spawn(.anonymous, self.stopOnMessage)
        let refB: ActorRef<String> = try first.spawn(.anonymous, self.stopOnMessage)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "test")

        first.receptionist.register(refA, key: key, replyTo: registeredProbe.ref)
        _ = try registeredProbe.expectMessage()

        first.receptionist.register(refB, key: key, replyTo: registeredProbe.ref)
        _ = try registeredProbe.expectMessage()

        second.receptionist.subscribe(key: key, subscriber: remoteLookupProbe.ref)
        _ = try remoteLookupProbe.expectMessage()

        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        try remoteLookupProbe.eventuallyExpectListing(expected: [refA, refB], within: .seconds(3))

        switch killActors {
        case .sendStop:
            refA.tell("stop")
            refB.tell("stop")
        case .shutdownNode:
            first.shutdown().wait()
        }

        try remoteLookupProbe.eventuallyExpectListing(expected: [], within: .seconds(3))
    }

    func test_clusterReceptionist_shouldRemoveRemoteRefs_whenTheyStop() throws {
        try self.shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: .sendStop)
    }

    func test_clusterReceptionist_shouldRemoveRemoteRefs_whenNodeDies() throws {
        try self.shared_clusterReceptionist_shouldRemoveRemoteRefsStop(killActors: .shutdownNode)
    }

    func test_clusterReceptionist_shouldRemoveRefFromAllListingsItWasRegisteredWith_ifTerminates() throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
        }
        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        let firstKey = Receptionist.RegistrationKey(ActorRef<String>.self, id: "first")
        let extraKey = Receptionist.RegistrationKey(ActorRef<String>.self, id: "extra")

        let ref = try first.spawn("hi", self.stopOnMessage)
        first.receptionist.register(ref, key: firstKey)
        first.receptionist.register(ref, key: extraKey)

        let p1f = self.testKit(first).spawnTestProbe("p1f", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p1e = self.testKit(first).spawnTestProbe("p1e", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p2f = self.testKit(second).spawnTestProbe("p2f", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p2e = self.testKit(second).spawnTestProbe("p2e", expecting: Receptionist.Listing<ActorRef<String>>.self)

        // ensure the ref is registered and known under both keys to both nodes
        first.receptionist.subscribe(key: firstKey, subscriber: p1f.ref)
        first.receptionist.subscribe(key: extraKey, subscriber: p1e.ref)

        second.receptionist.subscribe(key: firstKey, subscriber: p2f.ref)
        second.receptionist.subscribe(key: extraKey, subscriber: p2e.ref)

        func expectListingOnAllProbes(expected: Set<ActorRef<String>>) throws {
            try p1f.eventuallyExpectListing(expected: expected, within: .seconds(3))
            try p1e.eventuallyExpectListing(expected: expected, within: .seconds(3))

            try p2f.eventuallyExpectListing(expected: expected, within: .seconds(3))
            try p2e.eventuallyExpectListing(expected: expected, within: .seconds(3))
        }

        try expectListingOnAllProbes(expected: [ref])

        // terminate it
        ref.tell("stop!")

        // it should be removed from all listings; on both nodes, for all keys
        try expectListingOnAllProbes(expected: [])
    }

    func test_clusterReceptionist_shouldRemoveActorsOfTerminatedNodeFromListings_onNodeCrash() throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
        }
        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "key")

        let firstRef = try first.spawn("onFirst", self.stopOnMessage)
        first.receptionist.register(firstRef, key: key)

        let secondRef = try second.spawn("onSecond", self.stopOnMessage)
        second.receptionist.register(secondRef, key: key)

        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Receptionist.Listing<ActorRef<String>>.self)

        // ensure the ref is registered and known under both keys to both nodes
        first.receptionist.subscribe(key: key, subscriber: p1.ref)
        second.receptionist.subscribe(key: key, subscriber: p2.ref)

        try p1.eventuallyExpectListing(expected: [firstRef, secondRef], within: .seconds(3))
        try p2.eventuallyExpectListing(expected: [firstRef, secondRef], within: .seconds(3))

        // crash the second node
        second.shutdown().wait()

        // it should be removed from all listings; on both nodes, for all keys
        try p1.eventuallyExpectListing(expected: [firstRef], within: .seconds(5))
    }

    func test_clusterReceptionist_shouldRemoveManyRemoteActorsFromListingInBulk() throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
        }
        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "key")

        let firstRef = try first.spawn("onFirst", self.stopOnMessage)
        first.receptionist.register(firstRef, key: key)

        let remotes: [ActorRef<String>] = try (1 ... 100).map {
            let ref = try second.spawn("remote-\($0)", self.stopOnMessage)
            second.receptionist.register(ref, key: key)
            return ref
        }

        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Receptionist.Listing<ActorRef<String>>.self)

        // ensure the ref is registered and known under both keys to both nodes
        first.receptionist.subscribe(key: key, subscriber: p1.ref)
        second.receptionist.subscribe(key: key, subscriber: p2.ref)

        var allRefs = Set(remotes)
        allRefs.insert(firstRef)
        try p1.eventuallyExpectListing(expected: allRefs, within: .seconds(5))
        try p2.eventuallyExpectListing(expected: allRefs, within: .seconds(5))

        // crash the second node
        second.shutdown().wait()

        // it should be removed from all listings; on both nodes, for all keys
        try p1.eventuallyExpectListing(expected: [firstRef], within: .seconds(5), verbose: true)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Multi node / streaming

    func test_clusterReceptionist_shouldStreamAllRegisteredActorsInChunks() throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
        }
        first.cluster.join(node: second.cluster.node.node)
        try assertAssociated(first, withExactly: second.settings.cluster.uniqueBindNode)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "first")

        var allRefs: Set<ActorRef<String>> = []
        for i in 1 ... (first.settings.cluster.receptionist.syncBatchSize * 10) {
            let ref = try first.spawn("example-\(i)", self.stopOnMessage)
            first.receptionist.register(ref, key: key)
            _ = allRefs.insert(ref)
        }

        let p1 = self.testKit(first).spawnTestProbe("p1", expecting: Receptionist.Listing<ActorRef<String>>.self)
        let p2 = self.testKit(second).spawnTestProbe("p2", expecting: Receptionist.Listing<ActorRef<String>>.self)

        // ensure the ref is registered and known under both keys to both nodes
        first.receptionist.subscribe(key: key, subscriber: p1.ref)
        second.receptionist.subscribe(key: key, subscriber: p2.ref)

        try p1.eventuallyExpectListing(expected: allRefs, within: .seconds(10))
        try p2.eventuallyExpectListing(expected: allRefs, within: .seconds(10))
    }

    func test_clusterReceptionist_shouldSpreadInformationAmongManyNodes() throws {
        let (first, second) = setUpPair {
            $0.cluster.receptionist.ackPullReplicationIntervalSlow = .milliseconds(200)
        }
        let third = setUpNode("third")
        let fourth = setUpNode("fourth")

        try self.joinNodes(node: first, with: second)
        try self.joinNodes(node: first, with: third)
        try self.joinNodes(node: fourth, with: second)

        let key = Receptionist.RegistrationKey(ActorRef<String>.self, id: "key")

        let ref = try first.spawn("hi", self.stopOnMessage)
        first.receptionist.register(ref, key: key)

        func expectListingContainsRef(on system: ActorSystem) throws {
            let p = self.testKit(system).spawnTestProbe("p", expecting: Receptionist.Listing<ActorRef<String>>.self)
            system.receptionist.subscribe(key: key, subscriber: p.ref)

            try p.eventuallyExpectListing(expected: [ref], within: .seconds(3))
        }

        try expectListingContainsRef(on: first)
        try expectListingContainsRef(on: second)
        try expectListingContainsRef(on: third)
        try expectListingContainsRef(on: fourth)
    }
}
