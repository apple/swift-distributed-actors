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
    let context: Myself.Context
    let ownedListing: ActorableOwned<Reception.Listing<OwnerOfThings>>!

    init(
        context: Myself.Context, probe: ActorRef<Reception.Listing<OwnerOfThings>>,
        onListingUpdated: @escaping (ActorRef<Reception.Listing<OwnerOfThings>>, Reception.Listing<OwnerOfThings>) -> Void = { $0.tell($1) }
    ) {
        self.context = context
        context.receptionist.registerMyself(as: "all/owners")

        self.ownedListing = context.receptionist.autoUpdatedListing(OwnerOfThings.key)
        self.ownedListing.onUpdate { newValue in
            onListingUpdated(probe, newValue)
        }

        context.receptionist.registerMyself(as: Self.key.id)
    }

    func example(s: String, i: Int) -> Double {
        2.0
    }

    func readLastObservedValue() -> Reception.Listing<OwnerOfThings>? {
        self.ownedListing.lastObservedValue
    }

    // we can delegate to another actor directly; the Actor<OwnerOfThings> signature will not change
    // it always remains Reply<T> to whomever calls us, and we may implement it with a strictly, with a Reply, or AskResponse.
    func performLookup() -> Reply<Reception.Listing<OwnerOfThings>> {
        self.context.receptionist.lookup(.init(OwnerOfThings.self, id: "all/owners"), timeout: .effectivelyInfinite)
    }

    // if we HAD TO, we could still ask a ref directly and just expose this as well
    // for callers it still shows up as an Reply though.
    func performAskLookup() -> AskResponse<Receptionist.Listing<OwnerOfThings.Message>> {
        self.context.system.receptionist.ask(for: Receptionist.Listing<OwnerOfThings.Message>.self, timeout: .effectivelyInfinite) { ref in
            Receptionist.Lookup(key: .init(OwnerOfThings.Message.self, id: "all/owners"), replyTo: ref)
        }
    }

    func performSubscribe(p: ActorRef<Reception.Listing<OwnerOfThings>>) {
        self.context.receptionist.subscribe(.init(OwnerOfThings.self, id: "all/owners")) {
            p.tell($0)
        }
    }
}

extension OwnerOfThings {
    static let key = Reception.Key(OwnerOfThings.self, id: "owners-of-things")
}
