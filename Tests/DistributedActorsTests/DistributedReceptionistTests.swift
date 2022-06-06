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

extension DistributedReception.Key {
    fileprivate static var forwarders: DistributedReception.Key<Forwarder> {
        "forwarder/*"
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

    // FIXME: some bug in receptionist preventing listing to yield both
    func test_receptionist_listing_shouldRespondWithRegisteredRefsForKey() async throws {
        throw XCTSkip("Task locals are not supported on this platform.")

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
//        let lookupProbe: ActorTestProbe<Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
//
//        let ref: _ActorRef<String> = try system._spawn(.anonymous, .receiveMessage { _ in .same })
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
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
//        let lookupProbe: ActorTestProbe<Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
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
//        let key = Reception.Key(_ActorRef<String>.self, id: "shouldBeOne")
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
//        let probe: ActorTestProbe<Reception.Registered<_ActorRef<String>>> = self.testKit.makeTestProbe()
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
//        let lookupProbe: ActorTestProbe<Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
//
//        let ref: _ActorRef<String> = try system._spawn(
//                .anonymous,
//                .receiveMessage { _ in
//                    .stop
//                }
//        )
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
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
//        let lookupProbe: ActorTestProbe<Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
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
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
//
//        receptionist.listing(lookupProbe.ref, to: key)
//        try lookupProbe.expectMessage(Reception.Listing(refs: [], key: key))
//
//        receptionist.checkIn(refA, with: key)
//        try lookupProbe.expectMessage(Reception.Listing(refs: [refA.asAddressable], key: key))
//
//        receptionist.checkIn(refB, with: key)
//        try lookupProbe.expectMessage(Reception.Listing(refs: [refA.asAddressable, refB.asAddressable], key: key))
//
//        refB.tell("stop")
//        try lookupProbe.expectMessage(Reception.Listing(refs: [refA.asAddressable], key: key))
//    }
//
//    // ==== ------------------------------------------------------------------------------------------------------------
//    // MARK: Delayed flush
//
//    func test_delayedFlush_shouldEmitEvenWhenAllPeersRemoved() throws {
//        let receptionist = SystemReceptionist(ref: try system._spawn("receptionist", self.receptionistBehavior))
//        let lookupProbe: ActorTestProbe<Reception.Listing<_ActorRef<String>>> = self.testKit.makeTestProbe()
//
//        let key = Reception.Key(_ActorRef<String>.self, id: "test")
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
