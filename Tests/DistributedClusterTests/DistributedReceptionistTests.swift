//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
import Foundation
import XCTest
import Logging

@testable import DistributedCluster

final class DistributedReceptionistTests: SingleClusterSystemXCTestCase {
    let receptionistBehavior = _OperationLogClusterReceptionist(settings: .default).behavior

    func test_receptionist_mustHaveWellKnownID() throws {
        let opLogReceptionist = system.receptionist
        let id = opLogReceptionist.id

        id.metadata.wellKnown.shouldEqual("receptionist")
        id.incarnation.shouldEqual(.wellKnown)
    }

    func test_receptionist_shouldRespondWithRegisteredRefsForKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist
            let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

            let forwarderA = Forwarder(probe: probe, name: "A", actorSystem: system)
            let forwarderB = Forwarder(probe: probe, name: "B", actorSystem: system)

            await receptionist.checkIn(forwarderA, with: .forwarders)
            await receptionist.checkIn(forwarderB, with: .forwarders)

            let listing = await receptionist.lookup(.forwarders)
            listing.count.shouldEqual(2)
            for forwarder in listing {
                try await forwarder.forward(message: "test")
            }

            try probe.expectMessagesInAnyOrder([
                "\(forwarderA.id) A forwarded: test",
                "\(forwarderB.id) B forwarded: test",
            ])
        }
    }

    func test_receptionist_listing_shouldRespondWithRegisteredRefsForKey() async throws {
        let receptionist = system.receptionist
        let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let forwarderA = Forwarder(probe: probe, name: "A", actorSystem: system)
        let forwarderB = Forwarder(probe: probe, name: "B", actorSystem: system)

        system.log.notice("Checking in: \(forwarderA.id)")
        await receptionist.checkIn(forwarderA, with: .forwarders)
        system.log.notice("Checking in: \(forwarderB.id)")
        await receptionist.checkIn(forwarderB, with: .forwarders)

        var i = 0
        system.log.notice("here")
        for await forwarder in await receptionist.listing(of: .forwarders) {
            system.log.notice("here more \(i): \(forwarder.id)")
            i += 1
            try await forwarder.forward(message: "test")

            if i == 2 {
                break
            }
        }

        try probe.expectMessagesInAnyOrder([
            "\(forwarderA.id) A forwarded: test",
            "\(forwarderB.id) B forwarded: test",
        ])
    }

    func test_receptionist_listing_shouldEndAfterTaskIsCancelled() async throws {
        let receptionist = self.system.receptionist
        let probeA: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let probeB: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let bossA = Boss(probe: probeA, name: "A", actorSystem: self.system)
        let bossB = Boss(probe: probeB, name: "B", actorSystem: self.system)

        let workerA = Worker(name: "A", actorSystem: self.system)
        let workerB = Worker(name: "B", actorSystem: self.system)
        let workerC = Worker(name: "C", actorSystem: self.system)

        try await bossA.findWorkers()
        try await bossB.findWorkers()

        await receptionist.checkIn(workerA, with: .workers)

        try probeA.expectMessage("\(bossA.id) A found \(workerA.id)")
        try probeB.expectMessage("\(bossB.id) B found \(workerA.id)")

        try await bossB.done()
        try probeB.expectMessage("B done")

        await receptionist.checkIn(workerB, with: .workers)

        try probeA.expectMessage("\(bossA.id) A found \(workerB.id)")
        try probeB.expectNoMessage(for: .milliseconds(500))

        try await bossA.done()
        try probeA.expectMessage("A done")

        await receptionist.checkIn(workerC, with: .workers)

        try probeA.expectNoMessage(for: .milliseconds(500))
        try probeB.expectNoMessage(for: .milliseconds(500))
    }

    func test_receptionist_shouldRespondWithEmptyRefForUnknownKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist

            let ref = Forwarder(probe: nil, name: "C", actorSystem: system)
            await receptionist.checkIn(ref, with: .forwarders)

            let listing = await receptionist.lookup(.unknown)
            listing.count.shouldEqual(0)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------

    func test_receptionist_shouldNotRegisterTheSameRefTwice() async throws {
        let ref = Forwarder(probe: nil, name: "D", actorSystem: system)

        await system.receptionist.checkIn(ref, with: .forwarders)
        await system.receptionist.checkIn(ref, with: .forwarders)

        let listing = await system.receptionist.lookup(.forwarders)

        listing.count.shouldEqual(1)
    }

    func test_receptionist_happyPath_lookup_only() async throws {
        let (first, second) = await self.setUpPair { settings in
            settings.enabled = true
        }

        let ref = Forwarder(probe: nil, name: "D", actorSystem: first)
        await first.receptionist.checkIn(ref, with: .forwarders)

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        try await first.cluster.joined(node: second.cluster.node, within: .seconds(30))

        try await testKit.eventually(within: .seconds(5)) {
            let lookup = await second.receptionist.lookup(.forwarders)
            guard let first = lookup.first, lookup.count == 1 else {
                throw TestError("Lookup returned but is empty: \(lookup)")
            }
            first.id.shouldEqual(ref.id)
        }
    }

    func test_receptionist_happyPath_lookup_then_listing() async throws {
        let (first, second) = await self.setUpPair { settings in
            settings.enabled = true
        }

        let ref = Forwarder(probe: nil, name: "D", actorSystem: first)
        await first.receptionist.checkIn(ref, with: .forwarders)

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        try await first.cluster.joined(node: second.cluster.node, within: .seconds(30))

        try await testKit.eventually(within: .seconds(5)) {
            let lookup = await second.receptionist.lookup(.forwarders)
            guard let first = lookup.first, lookup.count == 1 else {
                throw TestError("Lookup returned but is empty: \(lookup)")
            }
            first.id.shouldEqual(ref.id)

            let listing = await second.receptionist.listing(of: .forwarders)
            for await forwarder in listing {
                forwarder.id.shouldEqual(ref.id)
                return
            }
        }
    }

    func test_receptionist_shouldRemoveAndAddNewSingletonRef() async throws {
        var old: Forwarder? = Forwarder(probe: nil, name: "old", actorSystem: system)
        let new = Forwarder(probe: nil, name: "new", actorSystem: system)

        await system.receptionist.checkIn(old!, with: .forwarders)

        try await self.testKit.eventually(within: .seconds(2)) {
            let lookup = await system.receptionist.lookup(.forwarders)
            if lookup.count != 1 {
                throw Boom("Expected lookup to contain ONLY \(old!.id), but was: \(lookup)")
            }
        }

        // release the old ref
        old = nil
        await system.receptionist.checkIn(new, with: .forwarders)

        try await self.testKit.eventually(within: .seconds(5)) {
            let lookup = await system.receptionist.lookup(.forwarders)
            if lookup.count != 1 {
                throw Boom("Listing had more members than 1, expected 1, was: \(lookup)")
            }
        }
    }

    //    func test_receptionist_shouldReplyWithRegistered() throws {
    //        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
    //        let probe: ActorTestProbe<_Reception.Registered<_ActorRef<String>>> = self.testKit.makeTestProbe()
    //
    //        let key = DistributedReception.Key(_ActorRef<String>.self, id: "test")
    //
    //        receptionist.checkIn(ref, with: key, replyTo: probe.ref)
    //
    //        let checkedIn = try probe.expectMessage()
    //
    //        checkedIn.key.id.shouldEqual(key.id)
    //        checkedIn.ref.shouldEqual(ref)
    //    }
    //
    //    func test_receptionist_shouldCheckOutTerminatedRefs() throws {
    //        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
    //        let lookupProbe: ActorTestProbe<_Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
    //
    //        let ref: _ActorRef<String> = try system._spawn(
    //                .anonymous,
    //                .receiveMessage { _ in
    //                    .stop
    //                }
    //        )
    //
    //        let key = _Reception.Key(_ActorRef<String>.self, id: "test")
    //
    //        receptionist.checkIn(ref, with: key)
    //
    //        ref.tell("stop")
    //
    //        try self.testKit.eventually(within: .seconds(1)) {
    //            receptionist.lookup(key, replyTo: lookupProbe.ref)
    //            let message = try lookupProbe.expectMessage()
    //
    //            // TODO: modify TestKit to allow usage of matchers instead
    //            guard message.refs.isEmpty else {
    //                throw self.testKit.error()
    //            }
    //        }
    //    }
    //
    //    func test_receptionist_shouldContinuouslySendUpdatesForSubscriptions() throws {
    //        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
    //        let lookupProbe: ActorTestProbe<_Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
    //
    //        let refA: _ActorRef<String> = try system._spawn(
    //                .anonymous,
    //                .receiveMessage { _ in
    //                    .same
    //                }
    //        )
    //
    //        let refB: _ActorRef<String> = try system._spawn(
    //                .anonymous,
    //                .receiveMessage { _ in
    //                    .stop
    //                }
    //        )
    //
    //        let key = _Reception.Key(_ActorRef<String>.self, id: "test")
    //
    //        receptionist.listing(lookupProbe.ref, to: key)
    //        try lookupProbe.expectMessage(_Reception.Listing(refs: [], key: key))
    //
    //        receptionist.checkIn(refA, with: key)
    //        try lookupProbe.expectMessage(_Reception.Listing(refs: [refA.asAddressable], key: key))
    //
    //        receptionist.checkIn(refB, with: key)
    //        try lookupProbe.expectMessage(_Reception.Listing(refs: [refA.asAddressable, refB.asAddressable], key: key))
    //
    //        refB.tell("stop")
    //        try lookupProbe.expectMessage(_Reception.Listing(refs: [refA.asAddressable], key: key))
    //    }
    //
    //    // ==== ------------------------------------------------------------------------------------------------------------
    //    // MARK: Delayed flush
    //
    //    func test_delayedFlush_shouldEmitEvenWhenAllPeersRemoved() throws {
    //        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
    //        let lookupProbe: ActorTestProbe<_Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
    //
    //        let key = _Reception.Key(_ActorRef<String>.self, id: "test")
    //
    //        receptionist.listing(lookupProbe.ref, to: key)
    //        _ = try lookupProbe.expectMessage()
    //
    //        receptionist.checkIn(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
    //        receptionist.checkIn(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
    //        receptionist.checkIn(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
    //
    //        // we're expecting to get the update in batch, thanks to the delayed flushing
    //        let listing1 = try lookupProbe.expectMessage()
    //        listing1.count.shouldEqual(3)
    //    }
}

distributed actor Forwarder {
    typealias ActorSystem = ClusterSystem
    let probe: ActorTestProbe<String>?
    let name: String

    init(probe: ActorTestProbe<String>?, name: String, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        self.name = name
    }

    distributed func forward(message: String) {
        self.probe?.tell("\(self.id) \(self.name) forwarded: \(message)")
    }
}

private distributed actor Boss: LifecycleWatch {
    typealias ActorSystem = ClusterSystem
    let probe: ActorTestProbe<String>?
    let name: String

    var workers: Set<ActorID> = []

    var listingTask: Task<Void, Never>?

    init(probe: ActorTestProbe<String>?, name: String, actorSystem: ActorSystem) {
        self.probe = probe
        self.actorSystem = actorSystem
        self.name = name
    }

    distributed func findWorkers() {
        guard self.listingTask == nil else {
            self.actorSystem.log.info("\(self.id) \(self.name) already looking for workers")
            return
        }

        self.listingTask = Task {
            for await worker in await self.actorSystem.receptionist.listing(of: .workers) {
                self.workers.insert(watchTermination(of: worker).id)
                self.probe?.tell("\(self.id) \(self.name) found \(worker.id)")
            }
        }
    }

    func terminated(actor id: ActorID) async {
        self.workers.remove(id)
    }

    distributed func done() {
        self.listingTask?.cancel()
        self.probe?.tell("\(self.name) done")
    }

    deinit {
        self.listingTask?.cancel()
        self.probe?.tell("\(self.name) deinit")
    }
}

private distributed actor Worker: CustomStringConvertible {
    typealias ActorSystem = ClusterSystem
    let name: String

    init(name: String, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.name = name
    }

    nonisolated var description: String {
        "\(Self.self) \(self.id)"
    }
}

extension DistributedReception.Key {
    fileprivate static var forwarders: DistributedReception.Key<Forwarder> {
        "forwarder/*"
    }

    fileprivate static var workers: DistributedReception.Key<Worker> {
        "worker/*"
    }

    /// A key that shall have NONE actors checked in
    fileprivate static var unknown: DistributedReception.Key<Forwarder> {
        "unknown"
    }
}
