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

class ClusterReceptionistTests: ClusteredNodesTestBase {
    func test_clusterReceptionist_shouldReplicateRegistrations() throws {
        let (local, remote) = setUpPair()

        let probe = self.testKit(local).spawnTestProbe(expecting: String.self)
        let registeredProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Registered<String>.self)
        let lookupProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Listing<String>.self)

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let ref: ActorRef<String> = try local.spawnAnonymous(
            .receiveMessage {
                probe.tell("received:\($0)")
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        remote.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: lookupProbe.ref))

        _ = try lookupProbe.expectMessage()

        local.receptionist.tell(Receptionist.Register(ref, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        let listing = try lookupProbe.expectMessage()
        listing.refs.count.shouldEqual(1)
        guard let registeredRef = listing.refs.first else {
            throw lookupProbe.error("listing contained no entries, expected 1")
        }
        registeredRef.tell("test")

        try probe.expectMessage("received:test")
    }

    func test_clusterReceptionist_shouldSyncPeriodically() throws {
        let (local, remote) = setUpPair {
            $0.cluster.receptionistSyncInterval = .milliseconds(100)
        }

        let probe = self.testKit(local).spawnTestProbe(expecting: String.self)
        let registeredProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Registered<String>.self)
        let lookupProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Listing<String>.self)

        let ref: ActorRef<String> = try local.spawnAnonymous(
            .receiveMessage {
                probe.tell("received:\($0)")
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

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

    func test_clusterReceptionist_shouldMergeEntriesOnSync() throws {
        let (local, remote) = setUpPair {
            $0.cluster.receptionistSyncInterval = .milliseconds(100)
        }

        let registeredProbe = self.testKit(local).spawnTestProbe(name: "registeredProbe", expecting: Receptionist.Registered<String>.self)
        let localLookupProbe = self.testKit(local).spawnTestProbe(name: "localLookupProbe", expecting: Receptionist.Listing<String>.self)
        let remoteLookupProbe = self.testKit(remote).spawnTestProbe(name: "remoteLookupProbe", expecting: Receptionist.Listing<String>.self)

        let behavior: Behavior<String> = .receiveMessage { _ in
            return .same
        }

        let refA: ActorRef<String> = try local.spawn(behavior, name: "refA")
        let refB: ActorRef<String> = try local.spawn(behavior, name: "refB")
        let refC: ActorRef<String> = try remote.spawn(behavior, name: "refC")
        let refD: ActorRef<String> = try remote.spawn(behavior, name: "refD")

        let key = Receptionist.RegistrationKey(String.self, id: "test")

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

    // TODO: remote watches are not yet implemented, so this does not work yet. Re-enable once https://github.com/apple/swift-distributed-actors/issues/609 is resolved
    func disabled_clusterReceptionist_shouldRemoveRemoteRefsWhenNodeDies() throws {
        let (local, remote) = setUpPair {
            $0.cluster.receptionistSyncInterval = .milliseconds(100)
        }

        let registeredProbe = self.testKit(local).spawnTestProbe(expecting: Receptionist.Registered<String>.self)
        let remoteLookupProbe = self.testKit(remote).spawnTestProbe(expecting: Receptionist.Listing<String>.self)

        let behavior: Behavior<String> = .receiveMessage { _ in
            return .stop
        }

        let refA: ActorRef<String> = try local.spawnAnonymous(behavior)
        let refB: ActorRef<String> = try local.spawnAnonymous(behavior)

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        local.receptionist.tell(Receptionist.Register(refA, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        local.receptionist.tell(Receptionist.Register(refB, key: key, replyTo: registeredProbe.ref))
        _ = try registeredProbe.expectMessage()

        remote.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: remoteLookupProbe.ref))
        _ = try remoteLookupProbe.expectMessage()

        local.cluster.join(node: remote.cluster.node.node)
        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)

        let remoteListing = try remoteLookupProbe.expectMessage()
        remoteListing.refs.count.shouldEqual(2)

        refA.tell("stop")
        refB.tell("stop")

        try remoteLookupProbe.expectMessage(within: .seconds(1)).refs.count.shouldEqual(1)
        try remoteLookupProbe.expectMessage(within: .seconds(1)).refs.count.shouldEqual(0)
    }
}
