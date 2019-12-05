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
import class NIO.EventLoopFuture

struct OwnerOfThings: Actorable {
    let context: Myself.Context
    let ownedListing: ActorableOwned<Reception.Listing<OwnerOfThings>>!

    init(context: Myself.Context, probe: ActorRef<Reception.Listing<OwnerOfThings>>) {
        self.context = context
        self.ownedListing = context.receptionist.autoUpdatedListing(OwnerOfThings.key)
        self.ownedListing.onUpdate { newValue in
            probe.tell(newValue)
        }

        context.receptionist.registerMyself(as: Self.key.id)
    }

    func readLastObservedValue() -> Reception.Listing<OwnerOfThings>? {
        self.ownedListing.lastObservedValue
    }

    func performLookup() -> EventLoopFuture<Reception.Listing<OwnerOfThings>> {
        let reply = self.context.receptionist.lookup(.init(OwnerOfThings.self, id: "all/owners"), timeout: .effectivelyInfinite)
        return reply._nioFuture
    }
}

extension OwnerOfThings {
    static let key = Reception.Key(OwnerOfThings.self, id: "owners-of-things")
}
