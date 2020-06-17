//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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

final class ActorContextReceptionTests: ActorSystemXCTestCase {
    func test_autoUpdatedListing_updatesAutomatically() throws {
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: self.system.deadLetters.adapted())
        }

        let listing: Receptionist.Listing<OwnerOfThings> = try self.testKit.eventually(within: .seconds(3)) {
            let readReply = owner.readLastObservedValue()
            guard let listing = try readReply.wait() else {
                throw self.testKit.error("No listing received")
            }
            guard listing.actors.first != nil else {
                throw self.testKit.error("Listing received, but it is empty (\(listing))")
            }
            return listing
        }

        listing.actors.first.shouldEqual(owner)
    }

    func test_autoUpdatedListing_invokesOnUpdate() throws {
        let p = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }

        let listing0: Receptionist.Listing<OwnerOfThings> = Receptionist.Listing<OwnerOfThings>(refs: Set())
        try p.expectMessage(listing0)
        let listing1: Receptionist.Listing<OwnerOfThings> = Receptionist.Listing<OwnerOfThings>(refs: Set([owner.ref]))
        try p.expectMessage(listing1)
    }

    func test_lookup_ofGenericType() throws {
        let notUsed = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: notUsed.ref)
        }

        let reply = owner.performLookup()
        try reply.wait().first.shouldEqual(owner)
    }

    func test_lookup_ofGenericType_exposedAskResponse_stillIsAReply() throws {
        let notUsed = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: notUsed.ref)
        }

        let reply: Reply<Receptionist.Listing<OwnerOfThings.Message>> = owner.performAskLookup()
        try reply.wait().refs.first.shouldEqual(owner.ref)
    }

    func test_subscribe_genericType() throws {
        let p = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }

        let ps = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)

        owner.performSubscribe(p: ps.ref)
        try ps.expectMessage(.init(refs: [owner.ref]))

        let anotherOwner = try self.system.spawn("anotherOwner") { OwnerOfThings(context: $0, probe: p.ref) }
        try ps.expectMessage(.init(refs: [owner.ref, anotherOwner.ref]))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Performance

    func test_autoUpdatedListing_shouldQuicklyUpdateFromThousandsOfUpdates() throws {
        let p = self.testKit.spawnTestProbe(expecting: Receptionist.Listing<OwnerOfThings>.self)
        let n = 2000

        _ = try! self.system.spawn("owner") {
            OwnerOfThings(
                context: $0,
                probe: p.ref,
                onListingUpdated: { probe, newValue in
                    if newValue.actors.count == n {
                        probe.tell(newValue)
                    }
                }
            )
        }

        for _ in 1 ... n {
            let ref: ActorRef<OwnerOfThings.Message> = try! self.system.spawn(
                .prefixed(with: "owner"),
                .receive { _, _ in
                    .same
                }
            )
            self.system.receptionist.register(ref, key: .init(messageType: OwnerOfThings.Message.self, id: "owners-of-things"))
        }

        let listing = try! p.expectMessage(within: .seconds(60))
        listing.actors.count.shouldEqual(n)
    }
}
