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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context Receptionist

extension Actor.Context {

    var receptionist: Self.Receptionist {
        Self.Receptionist(context: self)
    }

}

public typealias SystemReceptionist = Receptionist

extension Actor.Context {
    typealias Myself = Actor<A>

    struct Receptionist {
        let context: Myself.Context

        private var underlying: ActorContext<A.Message> {
            self.context.underlying
        }

        func register(_ key: SystemReceptionist.RegistrationKey<Myself.Message>) {
            self.underlying.system.receptionist.register(self.underlying.myself, key: key)
        }


        // could return Combine.Publisher if we could make it safe inside the actor context
        func subscribe<M>(_ key: SystemReceptionist.RegistrationKey<M>, onListingChange: @escaping (SystemReceptionist.Listing<M>) -> Void) {
            self.underlying.system.receptionist.subscribe(key: key, subscriber: self.underlying.subReceive("subscribe-\(key)", SystemReceptionist.Listing<M>.self) { listing in
                onListingChange(listing)
            })
        }

        // TODO: make those able to find Actorables
        func lookup<M>(_ key: SystemReceptionist.RegistrationKey<M>, onListing: @escaping (SystemReceptionist.Listing<M>) -> Void) {
            self.underlying.system.receptionist.tell(SystemReceptionist.Lookup(key: key, replyTo: self.underlying.subReceive("lookup-\(key)", SystemReceptionist.Listing<M>.self) { listing in
                onListing(listing)
            }))
        }
    }
}
