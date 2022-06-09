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
                self.workers.insert(worker.id)
                self.probe?.tell("\(self.id) \(self.name) found \(worker.id)")
            }
        }
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

final class DistributedReceptionistTests: ClusterSystemXCTestCase {
    let receptionistBehavior = _OperationLogClusterReceptionist(settings: .default).behavior

    func test_receptionist_mustHaveWellKnownAddress() throws {
        let opLogReceptionist = system.receptionist
        let receptionistAddress = opLogReceptionist.id

        receptionistAddress.detailedDescription.shouldEqual("/system/receptionist")
        receptionistAddress.incarnation.shouldEqual(.wellKnown)
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

    // FIXME: don't use runAsyncAndBlock [#953](https://github.com/apple/swift-distributed-actors/issues/953)
    func test_receptionist_listing_shouldRespondWithRegisteredRefsForKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist
            let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

            let forwarderA = Forwarder(probe: probe, name: "A", actorSystem: system)
            let forwarderB = Forwarder(probe: probe, name: "B", actorSystem: system)

            await receptionist.checkIn(forwarderA, with: .forwarders)
            await receptionist.checkIn(forwarderB, with: .forwarders)

            var i = 0
            for await forwarder in await receptionist.listing(of: .forwarders) {
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
    }

    // FIXME: don't use runAsyncAndBlock [#953](https://github.com/apple/swift-distributed-actors/issues/953)
    func test_receptionist_listing_shouldEndAfterTaskIsCancelled() throws {
        try runAsyncAndBlock {
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

//    func test_receptionist_shouldNotRegisterTheSameRefTwice() throws {
//        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
//        let lookupProbe: ActorTestProbe<_Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
//
//        let ref: _ActorRef<String> = try system._spawn(.anonymous, .receiveMessage { _ in .same })
//
//        let key = _Reception.Key(_ActorRef<String>.self, id: "test")
//
//        receptionist.checkIn(ref, with: key)
//        receptionist.checkIn(ref, with: key)
//
//        receptionist.lookup(key, replyTo: lookupProbe.ref)
//
//        let listing = try lookupProbe.expectMessage()
//
//        listing.refs.count.shouldEqual(1)
//    }
//
//    func test_receptionist_shouldRemoveAndAddNewSingletonRef() throws {
//        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
//        let lookupProbe: ActorTestProbe<_Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
//
//        let old: _ActorRef<String> = try system._spawn(
//                .anonymous,
//                .receive { context, _ in
//                    context.log.info("Stopping...")
//                    return .stop
//                }
//        )
//        let new: _ActorRef<String> = try system._spawn(
//                .anonymous,
//                .receiveMessage { _ in
//                    .same
//                }
//        )
//
//        let key = _Reception.Key(_ActorRef<String>.self, id: "shouldBeOne")
//
//        receptionist.checkIn(old, with: key)
//        old.tell("stop")
//        receptionist.checkIn(new, with: key)
//
//        try self.testKit.eventually(within: .seconds(2)) {
//            receptionist.lookup(key, replyTo: lookupProbe.ref)
//            let listing = try lookupProbe.expectMessage()
//
//            if listing.refs.count != 1 {
//                throw Boom("Listing had more members than 1, expected 1. Listing: \(listing.refs)")
//            }
//        }
//    }
//
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
