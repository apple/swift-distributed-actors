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

class ReceptionistTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        system = ActorSystem("TestSystem")
        testKit = ActorTestKit(system)
    }

    override func tearDown() {
        system.shutdown()
    }

    func test_receptionist_shouldRespondWithRegisteredRefsForKey() throws {
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let probe: ActorTestProbe<String> = testKit.spawnTestProbe()
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = testKit.spawnTestProbe()

        let refA: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                probe.tell("forwardedA:\(message)")
                return .same
            }
        )

        let refB: ActorRef<String> = try system.spawnAnonymous(
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
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .same
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
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key))
        receptionist.tell(Receptionist.Register(ref, key: key))

        receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))

        let listing = try lookupProbe.expectMessage()

        listing.refs.count.shouldEqual(1)
    }

    func test_receptionist_shouldReplyWithRegistered() throws {
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let probe: ActorTestProbe<Receptionist.Registered<String>> = testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .same
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key, replyTo: probe.ref))

        let registered = try probe.expectMessage()

        registered.key.id.shouldEqual(key.id)
        registered.ref.shouldEqual(ref)
    }

    func test_receptionist_shouldUnregisterTerminatedRefs() throws {
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = testKit.spawnTestProbe()

        let ref: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .stopped
            }
        )

        let key = Receptionist.RegistrationKey(String.self, id: "test")

        receptionist.tell(Receptionist.Register(ref, key: key))

        ref.tell("stop")

        try testKit.eventually(within: .seconds(1)) {
            receptionist.tell(Receptionist.Lookup(key: key, replyTo: lookupProbe.ref))
            let message = try lookupProbe.expectMessage()

            // TODO: modify TestKit to allow usage of matchers instead
            guard message.refs.isEmpty else {
                throw self.testKit.error()
            }
        }
    }

    func test_receptionist_shouldContinouslySendUpdatesForSubscriptions() throws {
        let receptionist = try system.spawn(LocalReceptionist.behavior, name: "receptionist")
        let lookupProbe: ActorTestProbe<Receptionist.Listing<String>> = testKit.spawnTestProbe()

        let refA: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .same
            }
        )

        let refB: ActorRef<String> = try system.spawnAnonymous(
            .receiveMessage { message in
                return .stopped
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
