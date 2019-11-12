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

    public var receptionist: Self.Receptionist {
        Self.Receptionist(context: self)
    }

}

public typealias SystemReceptionist = Receptionist

extension Actor.Context {
    public typealias Myself = Actor<A>

    public struct Receptionist {
        let context: Myself.Context

        private var underlying: ActorContext<A.Message> {
            self.context.underlying
        }

        func register(_ key: SystemReceptionist.RegistrationKey<Myself.Message>) {
            self.underlying.system.receptionist.register(self.underlying.myself, key: key)
        }


        // could return Combine.Publisher or our MultiTask? if we could make it safe inside the actor context
        // TODO abusing the registration key somewhat; it was intended to be message
        func subscribe<A: Actorable>(_ key: SystemReceptionist.RegistrationKey<A.Message>, onListingChange: @escaping (Receptionist.Listing<A>) -> Void) {
            self.underlying.system.receptionist.subscribe(key: key, subscriber: self.underlying.subReceive("subscribe-\(key)", SystemReceptionist.Listing<A.Message>.self) { listing in
                let actors = Set(listing.refs.map { ref in
                    Actor<A>(ref: ref)
                })
                onListingChange(Listing(actors: actors))
            })
        }

        // TODO: make those able to find Actorables
        func lookup<A: Actorable>(_ key: SystemReceptionist.RegistrationKey<A.Message>, onListing: @escaping (Receptionist.Listing<A>) -> Void) {
            self.underlying.system.receptionist.tell(SystemReceptionist.Lookup(key: key, replyTo: self.underlying.subReceive("lookup-\(key)", SystemReceptionist.Listing<A.Message>.self) { listing in
                let actors = Set(listing.refs.map { ref in
                    Actor<A>(ref: ref)
                })
                onListing(Listing(actors: actors))
            }))
        }

        struct Listing<A: Actorable> {
            let actors: Set<Actor<A>>
        }

    }
}
