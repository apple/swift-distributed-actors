//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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

final class ActorContextReceptionTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_autoUpdatedListing_updatesAutomatically() throws {
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") { OwnerOfThings(context: $0, probe: self.system.deadLetters.adapted()) }

        let listing: Reception.Listing<OwnerOfThings> = try self.testKit.eventually(within: .seconds(1)) {
            let readFuture = owner.readLastObservedValue()
            guard let listing = try readFuture._nioFuture.wait() else {
                throw self.testKit.error()
            }
            return listing
        }

        listing.actors.first!.shouldEqual(owner)
    }

    func test_autoUpdatedListing_invokesOnUpdate() throws {
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") { OwnerOfThings(context: $0, probe: p.ref) }

        let listing0: Reception.Listing<OwnerOfThings> = Reception.Listing<OwnerOfThings>(actors: Set())
        try p.expectMessage(listing0)
        let listing1: Reception.Listing<OwnerOfThings> = Reception.Listing<OwnerOfThings>(actors: Set([owner]))
        try p.expectMessage(listing1)
    }

    func test_lookup_ofGenericType() throws {
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<OwnerOfThings>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") { OwnerOfThings(context: $0, probe: p.ref) }

        let reply = owner.performLookup()
        try reply._nioFuture.wait().first.shouldEqual(owner)
    }
}
