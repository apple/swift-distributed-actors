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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class ReceptionistTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_receptionist_shouldRespondWithRegisteredRefsForKey() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let probe: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let refA: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { message in
                probe.tell("forwardedA:\(message)")
                return .same
            }
        )

        let refB: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { message in
                probe.tell("forwardedB:\(message)")
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(refA, key: key))
        receptionist.tell(Receptionist.Register(refB, key: key))
        receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))

        let listing = try lookupProbe.expectMessage()

        listing.refs.count.shouldEqual(2)
        for ref in listing.refs {
            ref.tell("test")
        }

        try probe.expectMessagesInAnyOrder(["forwardedA:test", "forwardedB:test"])
    }

    func test_receptionist_shouldRespondWithEmptyRefForUnknownKey() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key))

        let unknownKey = Receptionist.RegistrationKey(String.self, id: "unknown")
        receptionist.tell(Receptionist.Lookup(key: unknownKey, replyTo: lookupProbe.ref))

        let listing = try lookupProbe.expectMessage()

        listing.refs.count.shouldEqual(0)
    }

    func test_receptionist_shouldNotRegisterTheSameRefTwice() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key))
        receptionist.tell(Receptionist.Register(ref, key: key))

        receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))

        let listing = try lookupProbe.expectMessage()

        listing.refs.count.shouldEqual(1)
    }

    func test_receptionist_shouldRemoveAndAddNewSingletonRef() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let old: ActorRef<String> = try system.spawn(
            .anonymous,
            .receive { context, _ in
                context.log.info("Stopping...")
                return .stop
            }
        )
        let new: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "shouldBeOne")

        receptionist.tell(Receptionist.Register(old, key: key))
        old.tell("stop")
        receptionist.tell(Receptionist.Register(new, key: key))

        try self.testKit.eventually(within: .seconds(2)) {
            receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))
            let listing = try lookupProbe.expectMessage()

            if listing.refs.count != 1 {
                throw Boom("Listing had more members than 1, expected 1. Listing: \(listing.refs)")
            }
        }
    }

    func test_receptionist_shouldReplyWithRegistered() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let probe: ActorTestProbe<Receptionist.Registered<String>> = self.testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key, replyTo: probe.ref))

        let registered = try probe.expectMessage()

        registered.key.id.shouldEqual(key.id)
        registered.ref.shouldEqual(ref)
    }

    func test_receptionist_shouldUnregisterTerminatedRefs() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .stop
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key))

        ref.tell("stop")

        try self.testKit.eventually(within: .seconds(1)) {
            receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))
            let message = try lookupProbe.expectMessage()

            // TODO: modify TestKit to allow usage of matchers instead
            guard message.refs.isEmpty else {
                throw self.testKit.error()
            }
        }
    }

    func test_receptionist_shouldContinuouslySendUpdatesForSubscriptions() throws {
        let receptionist = try system.spawn("receptionist", LocalReceptionist.behavior)
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = self.testKit.spawnTestProbe()

        let refA: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .same
            }
        )

        let refB: ActorRef<String> = try system.spawn(
            .anonymous,
            .receiveMessage { _ in
                .stop
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Subscribe(key: key, subscriber: lookupProbe.ref))
        try lookupProbe.expectMessage(Receptionist.Listing(refs: []))

        receptionist.tell(Receptionist.Register(refA, key: key))
        try lookupProbe.expectMessage(Receptionist.Listing(refs: [refA]))

        receptionist.tell(Receptionist.Register(refB, key: key))
        try lookupProbe.expectMessage(Receptionist.Listing(refs: [refA, refB]))

        refB.tell("stop")
        try lookupProbe.expectMessage(Receptionist.Listing(refs: [refA]))
    }
}
