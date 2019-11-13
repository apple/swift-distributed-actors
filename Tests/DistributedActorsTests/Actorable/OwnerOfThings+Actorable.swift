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

import DistributedActors

struct OwnerOfThings: Actorable {
    let context: Myself.Context
    let ownedListing: ActorableOwned<Reception.Listing<OwnerOfThings>>!

    init(context: Myself.Context, probe: ActorRef<Reception.Listing<OwnerOfThings>>) {
        self.context = context
        self.ownedListing = context.receptionist.ownedListing(OwnerOfThings.key)
        self.ownedListing.onUpdate { newValue in
            probe.tell(newValue)
        }

        context.receptionist.register(as: Self.key.id)
    }

    func readLastObservedValue() -> Reception.Listing<OwnerOfThings>? {
        self.ownedListing.lastObservedValue
    }
}

extension OwnerOfThings {
    static let key = Reception.Key(OwnerOfThings.self, id: "owners-of-things")
}
