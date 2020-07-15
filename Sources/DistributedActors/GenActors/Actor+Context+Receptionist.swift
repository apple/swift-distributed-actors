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

import Dispatch
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<Act>.Context Receptionist

extension Actor.Context {
    public var receptionist: Self.Receptionist {
        Self.Receptionist(context: self)
    }
}

extension Actor.Context {
    public typealias Myself = Actor<Act>

    /// The receptionist enables type-safe and dynamic (subscription based) actor discovery.
    ///
    /// Actors may register themselves when they start with an `Reception.Key<A>`
    ///
    /// - SeeAlso: `DistributedActors.Receptionist` for the `ActorRef<Message>` version of this API.
    public struct Receptionist: MyselfReceptionistOperations {
        let context: Myself.Context

        // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
        public var _myself: Myself {
            self.context.myself
        }

        // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
        public var _underlyingContext: ActorContext<Act.Message> {
            self.context._underlying
        }

        // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
        public var _system: ActorSystem {
            self.context.system
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Actor<Act> specific receptionist functions

        /// An automatically managed (i.e. kept up to date, by an subscription for the passed in `key`) `Reception.Listing<Guest>`.
        ///
        /// SeeAlso: `ActorOwned<T>` for the general mechanism of actor owned values.
        /// SeeAlso: `subscribe(key:onListingChange:)` for a callback based version of this API.
        public func autoUpdatedListing<Guest>(
            _ key: Reception.Key<Guest>
        ) -> ActorableOwned<Reception.Listing<Guest>> where Guest: ReceptionistGuest {
            let owned: ActorableOwned<Reception.Listing<Guest>> = ActorableOwned(self.context)
            self.context._underlying.receptionist.subscribeMyself(to: key, subReceive: { listing in
                owned.update(newValue: listing)
            })

            return owned
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actorable Receptionist Listing

extension SystemReceptionist {
    // FIXME: remove this, use only one listing type
    struct ActorableListing<Act: Actorable>: ReceptionistListing, CustomStringConvertible {
        let refs: Set<ActorRef<Act.Message>>

        var description: String {
            "Listing<\(Act.self)>(\(self.refs.map { $0.address }))"
        }
    }
}

extension Reception.Listing where Guest: ActorProtocol {
    public var actors: LazyMapSequence<Set<AddressableActorRef>, Actor<Guest.Act>> {
        self.underlying.lazy.map { addressable in
            let ref: ActorRef<Guest.Message> = self.key._unsafeAsActorRef(addressable)
            return Actor<Guest.Act>(ref: ref)
        }
    }

    public var first: Actor<Guest.Act>? {
        self.underlying.first.map {
            let ref: ActorRef<Guest.Message> = self.key._unsafeAsActorRef($0)
            return Actor<Guest.Act>(ref: ref)
        }
    }

    public func first(where matches: (ActorAddress) -> Bool) -> Actor<Guest.Act>? {
        self.underlying.first {
            let ref: ActorRef<Guest.Message> = self.key._unsafeAsActorRef($0)
            return matches(ref.address)
        }.map {
            let ref: ActorRef<Guest.Message> = self.key._unsafeAsActorRef($0)
            return Actor<Guest.Act>(ref: ref)
        }
    }

    /// Returns the first actor from the listing whose name matches the passed in `name` parameter.
    ///
    /// Special handling is applied to message adapters (e.g. `/uses/example/two/$messageAdapter` in which case the last segment is ignored).
    public func first(named name: String) -> Actor<Guest.Act>? {
        self.underlying.first {
            $0.path.name == name ||
                ($0.path.segments.last?.value == "$messageAdapter" && $0.path.segments.dropLast(1).last?.value == name)
        }.map {
            let ref: ActorRef<Guest.Message> = self.key._unsafeAsActorRef($0)
            return Actor<Guest.Act>(ref: ref)
        }
    }
}
