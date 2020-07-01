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

        let listing: Reception.Listing<Actor<OwnerOfThings>> = try self.testKit.eventually(within: .seconds(3)) {
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
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }

        let listing1 = Reception.Listing<Actor<OwnerOfThings>>(refs: Set([owner.ref.asAddressable()]), key: .ownerOfThingsKey)
        try p.expectMessage(listing1)
    }

    func test_lookup_ofGenericType() throws {
        let notUsed = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: notUsed.ref)
        }

        let reply = owner.performLookup()
        try reply.wait().first.shouldEqual(owner)
    }

    func test_lookup_ofGenericType_exposedAskResponse_stillIsAReply() throws {
        let notUsed = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: notUsed.ref)
        }

        let listing: Reception.Listing<Actor<OwnerOfThings>> = try owner.performAskLookup().wait()
        listing.first.shouldEqual(owner)
    }

    func test_subscribe_genericType() throws {
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }

        let ps = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)

        owner.performSubscribe(p: ps.ref)
        try ps.expectMessage(.init(refs: [owner.ref.asAddressable()], key: .ownerOfThingsKey))

        let anotherOwner = try self.system.spawn("anotherOwner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }
        try ps.expectMessage(.init(refs: [owner.ref.asAddressable(), anotherOwner.ref.asAddressable()], key: .ownerOfThingsKey))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Performance

    func test_autoUpdatedListing_shouldQuicklyUpdateFromThousandsOfUpdates() throws {
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let n = 1000

        _ = try! self.system.spawn("owner") {
            OwnerOfThings(
                context: $0,
                probe: p.ref,
                onOwnedListingUpdated: { probe, newValue in
                    if newValue.actors.count == (n + 1) {
                        probe.tell(newValue)
                    }
                }
            )
        }

        for _ in 1 ... n {
            let ref: ActorRef<OwnerOfThings.Message> = try! self.system.spawn(
                .prefixed(with: "owner"),
                .receiveMessage { _ in .same }
            )
            self.system.receptionist.register(Actor(ref: ref), with: .ownerOfThingsKey)
        }

        let listing = try p.expectMessage(within: .seconds(3))
        listing.actors.count.shouldEqual(n + 1)
    }
}
