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

public typealias SystemReceptionist = Receptionist

extension Actor.Context {
    public typealias Myself = Actor<Act>

    /// The receptionist enables type-safe and dynamic (subscription based) actor discovery.
    ///
    /// Actors may register themselves when they start with an `Reception.Key<A>`
    ///
    /// - SeeAlso: `DistributedActors.Receptionist` for the `ActorRef<Message>` version of this API.
    public struct Receptionist {
        let context: Myself.Context

        private var underlying: ActorContext<Act.Message> {
            self.context._underlying
        }

        /// Registers `myself` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func registerMyself(as id: String) {
            self.registerMyself(with: Reception.Key(Myself.self, id: id))
        }

        /// Registers `myself` in the systems receptionist with given key.
        public func registerMyself(with key: Reception.Key<Myself>) {
            self.register( self.context.myself, key: key)
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<Guest>(
            _ guest: Guest,
            as id: String
        ) where Guest: ReceptionistGuest {
            self.register(guest, key: .init(Guest.self, id: id))
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<Guest>(
            _ guest: Guest,
            key: Reception.Key<Guest>
        ) where Guest: ReceptionistGuest {
            self.underlying.system.receptionist.register(guest, key: key)
        }

        /// Subscribe to actors registering under given `key`.
        ///
        /// A new `Reception.Listing<Guest>` is emitted whenever new actors join (or leave) the reception, and the `onListingChange` is then
        /// invoked on the actors context.
        ///
        /// Current Limitation: Only ONE (the most recently set using this API) `onListingChange` for a given `key` is going to be executed.
        /// This is done to avoid growing the number of callbacks infinitely, in case one would continuously invoke this API in every actorable call.
        ///
        /// - Parameters:
        ///   - key: selects which actors we are interested in.
        ///   - onListingChange: invoked whenever actors join/leave the reception or when they terminate.
        ///                      The invocation is made on the owning actor's context, meaning that it is safe to mutate actor state from the callback.
        ///
        /// SeeAlso: `autoUpdatedListing(_:)` for an automatically managed wrapped variable containing a `Reception.Listing<Guest>`
        public func subscribe<Guest>(
            _ key: Reception.Key<Guest>,
            onListingChange: @escaping (SystemReceptionist.Listing<Guest>) -> Void
        ) where Guest: ReceptionistGuest {
            // TODO: Implementing this without sub-receive would be preferable, as today we either create many subs or override them
            self.underlying.system.receptionist.subscribe(
                key: key,
                subscriber: self.underlying.subReceive(.init(id: String(reflecting: Act.self)), SystemReceptionist.Listing<Guest>.self) { listing in
                     onListingChange(listing)
                }
            )
        }

        /// An automatically managed (i.e. kept up to date, by an subscription for the passed in `key`) `Reception.Listing<Guest>`.
        ///
        /// SeeAlso: `ActorOwned<T>` for the general mechanism of actor owned values.
        /// SeeAlso: `subscribe(key:onListingChange:)` for a callback based version of this API.
        public func autoUpdatedListing<Guest>(
            _ key: Reception.Key<Guest>
        ) -> ActorableOwned<SystemReceptionist.Listing<Guest>> where Guest: ReceptionistGuest {
            let owned: ActorableOwned<SystemReceptionist.Listing<Guest>> = ActorableOwned(self.context)
            self.context.system.receptionist.subscribe(
                key: key,
                subscriber: self.context._underlying.subReceive(SystemReceptionist.Listing<Guest>.self) { listing in
                     owned.update(newValue: listing)
                }
            )

            return owned
        }

        /// Perform a single lookup for an `Actor<Act>` identified by the passed in `key`.
        ///
        /// - Parameters:
        ///   - key: selects which actors we are interested in.
        public func lookup<Guest>(
            _ key: Reception.Key<Guest>,
            timeout: TimeAmount
        ) -> Reply<SystemReceptionist.Listing<Guest>> {
            let listingReply: AskResponse<SystemReceptionist.Listing<Guest>> = self.underlying.system.receptionist.ask(timeout: timeout) {
                SystemReceptionist.Lookup(key: key, replyTo: $0)
            }
            return Reply.from(askResponse: listingReply)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reception

/// The `Reception` serves as holder of types related to the `Actorable` specific receptionist implementation.
public enum Reception {}

extension Reception {

    public typealias Key = Receptionist.RegistrationKey

//    /// Key used to identify Actors registered in `Actor.Context.Receptionist`.
//    /// Used to lookup actors of specific type and group `id`.
//    ///
//    /// - See `Receptionist.RegistrationKey` for the low-level `ActorRef` compatible key API
//    /// // TODO: deprecate and merge with RegistrationKey
//    public struct Key<Act: Actorable> {
//        public let underlying: SystemReceptionist.RegistrationKey<Act.Message>
//
//        public init(_ type: Act.Type = Act.self, id: String) {
//            self.underlying = .init(messageType: Act.Message.self, id: id)
//        }
//
//        public var id: String {
//            self.underlying.id
//        }
//    }
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

extension SystemReceptionist.Listing where Guest: ActorProtocol {

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

}
