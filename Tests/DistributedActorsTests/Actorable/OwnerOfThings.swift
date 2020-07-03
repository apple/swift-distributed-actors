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

import DistributedActors

struct OwnerOfThings: Actorable {
    enum Hello {
        case usedToBreakCodeGen
    }

    let context: Myself.Context
    let probe: ActorRef<Reception.Listing<Actor<OwnerOfThings>>>
    let ownedListing: ActorableOwned<Reception.Listing<Actor<OwnerOfThings>>>!

    init(
        context: Myself.Context,
        probe: ActorRef<Reception.Listing<Actor<OwnerOfThings>>>,
        onOwnedListingUpdated: @escaping (ActorRef<Reception.Listing<Actor<OwnerOfThings>>>, Reception.Listing<Actor<OwnerOfThings>>) -> Void = { $0.tell($1) }
    ) {
        self.context = context
        self.probe =
            context.receptionist.registerMyself(with: .ownerOfThingsKey)

        self.ownedListing = context.receptionist.autoUpdatedListing(.ownerOfThingsKey)
        self.ownedListing.onUpdate { newValue in
            onOwnedListingUpdated(probe, newValue)
        }

        context.receptionist.registerMyself(with: .ownerOfThingsKey)
    }

    // @actor
    func readLastObservedValue() -> Reception.Listing<Actor<OwnerOfThings>>? {
        self.ownedListing.lastObservedValue
    }

    // we can delegate to another actor directly; the Actor<OwnerOfThings> signature will not change
    // it always remains Reply<T> to whomever calls us, and we may implement it with a strictly, with a Reply, or AskResponse.
    // @actor
    func performLookup() -> AskResponse<Reception.Listing<Actor<OwnerOfThings>>> {
        self.context.receptionist.lookup(.ownerOfThingsKey)
    }

    // if we HAD TO, we could still ask a ref directly and just expose this as well
    // for callers it still shows up as an Reply though.
    // @actor
    func performAskLookup() -> AskResponse<Reception.Listing<Actor<OwnerOfThings>>> {
        self.context.receptionist.lookup(.ownerOfThingsKey)
    }

    // @actor
    func performSubscribe(p: ActorRef<Reception.Listing<Actor<OwnerOfThings>>>) {
        self.context.receptionist.subscribeMyself(to: .ownerOfThingsKey) {
            p.tell($0)
        }
    }

    func testSpawning() throws {
        try self.context.spawn("a") { OwnerOfThings(context: $0, probe: self.probe) }
        try self.context.spawn("b", props: Props(), .receiveMessage { _ in
            .stop
        })
    }
}

extension Reception.Key {
    static var ownerOfThingsKey: Reception.Key<Actor<OwnerOfThings>> {
        .init()
    }
}
