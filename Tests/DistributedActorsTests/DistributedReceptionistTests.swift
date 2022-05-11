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
        self.probe = probe
        self.name = name
    }

    distributed func forward(message: String) {
        probe?.tell("\(self.id.underlying) \(name) forwarded: \(message)")
    }
}

extension DistributedReception.Key {
    fileprivate static var forwarders: DistributedReception.Key<Forwarder> {
        "forwarder/*"
    }

    /// A key that shall have NONE actors registered
    fileprivate static var unknown: DistributedReception.Key<Forwarder> {
        "unknown"
    }
}

final class DistributedReceptionistTests: ActorSystemXCTestCase {
    let receptionistBehavior = _OperationLogClusterReceptionist(settings: .default).behavior

    func test_receptionist_mustHaveWellKnownAddress() throws {
        let opLogReceptionist = system.receptionist as! OpLogDistributedReceptionist
        let receptionistAddress = opLogReceptionist.id

        receptionistAddress.detailedDescription.shouldEqual("/system/receptionist")
        receptionistAddress.incarnation.shouldEqual(.wellKnown)
    }

    func test_receptionist_shouldRespondWithRegisteredRefsForKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist
            let probe: ActorTestProbe<String> = self.testKit.makeTestProbe()

            let forwarderA = Forwarder(probe: probe, name: "A", transport: system)
            let forwarderB = Forwarder(probe: probe, name: "B", transport: system)

            await receptionist.register(forwarderA, with: .forwarders)
            await receptionist.register(forwarderB, with: .forwarders)

            let listing = await receptionist.lookup(.forwarders)
            listing.count.shouldEqual(2)
            for forwarder in listing {
                try await forwarder.forward(message: "test")
            }

            try probe.expectMessagesInAnyOrder([
                "\(forwarderA.id.underlying) A forwarded: test",
                "\(forwarderB.id.underlying) B forwarded: test",
            ])
        }
    }

    func test_receptionist_shouldRespondWithEmptyRefForUnknownKey() throws {
        try runAsyncAndBlock {
            let receptionist = system.receptionist

            let ref = Forwarder(probe: nil, name: "C", transport: system)
            await receptionist.register(ref, with: .forwarders)

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
//        receptionist.register(ref, with: key)
//        receptionist.register(ref, with: key)
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
//        receptionist.register(old, with: key)
//        old.tell("stop")
//        receptionist.register(new, with: key)
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
//        receptionist.register(ref, with: key, replyTo: probe.ref)
//
//        let registered = try probe.expectMessage()
//
//        registered.key.id.shouldEqual(key.id)
//        registered.ref.shouldEqual(ref)
//    }
//
//    func test_receptionist_shouldUnregisterTerminatedRefs() throws {
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
//        receptionist.register(ref, with: key)
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
//        receptionist.subscribe(lookupProbe.ref, to: key)
//        try lookupProbe.expectMessage(Reception.Listing(refs: [], key: key))
//
//        receptionist.register(refA, with: key)
//        try lookupProbe.expectMessage(Reception.Listing(refs: [refA.asAddressable], key: key))
//
//        receptionist.register(refB, with: key)
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
//        receptionist.subscribe(lookupProbe.ref, to: key)
//        _ = try lookupProbe.expectMessage()
//
//        receptionist.register(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
//        receptionist.register(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
//        receptionist.register(try system._spawn(.anonymous, .receiveMessage { _ in .same }), with: key)
//
//        // we're expecting to get the update in batch, thanks to the delayed flushing
//        let listing1 = try lookupProbe.expectMessage()
//        listing1.count.shouldEqual(3)
//    }
}
