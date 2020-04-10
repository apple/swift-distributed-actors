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

import Dispatch
import Logging
import NIO

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

    /// The receptionist enables type-safe and dynamic (subscription based) actor discovery.
    ///
    /// Actors may register themselves when they start with an `Reception.Key<A>`
    ///
    /// - SeeAlso: `DistributedActors.Receptionist` for the `ActorRef<Message>` version of this API.
    public struct Receptionist {
        let context: Myself.Context

        private var underlying: ActorContext<A.Message> {
            self.context._underlying
        }

        /// Registers `myself` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        ///
        /// - SeeAlso: `register(actor:key:)`, `register(actor:as:)`
        public func registerMyself(as id: String) {
            self.register(actor: self.context.myself, key: Reception.Key(A.self, id: id))
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<Act: Actorable>(actor: Actor<Act>, as id: String) {
            self.register(actor: actor, key: .init(Act.self, id: id))
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<Act: Actorable>(actor: Actor<Act>, key: Reception.Key<Act>) {
            self.underlying.system.receptionist.register(actor.ref, key: key.underlying)
        }

        /// Subscribe to actors registering under given `key`.
        ///
        /// A new `Reception.Listing<Act>` is emitted whenever new actors join (or leave) the reception, and the `onListingChange` is then
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
        /// SeeAlso: `autoUpdatedListing(_:)` for an automatically managed wrapped variable containing a `Reception.Listing<Act>`
        public func subscribe<Act: Actorable>(_ key: Reception.Key<Act>, onListingChange: @escaping (Reception.Listing<Act>) -> Void) {
            // TODO: Implementing this without sub-receive would be preferable, as today we either create many subs or override them
            self.underlying.system.receptionist.subscribe(
                key: key.underlying,
                subscriber: self.underlying.subReceive(.init(id: String(reflecting: Act.self)), SystemReceptionist.Listing<Act.Message>.self) { listing in
                    onListingChange(.init(refs: listing.refs))
                }
            )
        }

        /// An automatically managed (i.e. kept up to date, by an subscription for the passed in `key`) `Reception.Listing<Act>`.
        ///
        /// SeeAlso: `ActorOwned<T>` for the general mechanism of actor owned values.
        /// SeeAlso: `subscribe(key:onListingChange:)` for a callback based version of this API.
        public func autoUpdatedListing<Act: Actorable>(_ key: Reception.Key<Act>) -> ActorableOwned<Reception.Listing<Act>> {
            let owned: ActorableOwned<Reception.Listing<Act>> = ActorableOwned(self.context)
            self.context.system.receptionist.subscribe(
                key: key.underlying,
                subscriber: self.context._underlying.subReceive(SystemReceptionist.Listing<Act.Message>.self) { listing in
                    owned.update(newValue: Reception.Listing(refs: listing.refs))
                }
            )

            return owned
        }

        /// Perform a single lookup for an `Actor<Act>` identified by the passed in `key`.
        ///
        /// - Parameters:
        ///   - key: selects which actors we are interested in.
        public func lookup<Act: Actorable>(_ key: Reception.Key<Act>, timeout: TimeAmount) -> Reply<Reception.Listing<Act>> {
            let listingReply: AskResponse<Reception.Listing<Act>> = self.underlying.system.receptionist.ask(timeout: timeout) {
                SystemReceptionist.Lookup(key: key.underlying, replyTo: $0)
            }.map { listing in
                Reception.Listing(refs: listing.refs)
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
    /// Key used to identify Actors registered in `Actor.Context.Receptionist`.
    /// Used to lookup actors of specific type and group `id`.
    ///
    /// - See `Receptionist.RegistrationKey` for the low-level `ActorRef` compatible key API
    public struct Key<Act: Actorable> {
        public let underlying: SystemReceptionist.RegistrationKey<Act.Message>

        public init(_ type: Act.Type = Act.self, id: String) {
            self.underlying = .init(messageType: Act.Message.self, id: id)
        }

        public var id: String {
            self.underlying.id
        }
    }

    /// Contains a list of actors looked up using a `Key`.
    /// A listing MAY be empty.
    ///
    /// - See `Receptionist.RegistrationKey` for the low-level `ActorRef` compatible key API
    public struct Listing<Act: Actorable>: ActorMessage, Equatable {
        public let refs: Set<ActorRef<Act.Message>>

        public var isEmpty: Bool {
            self.actors.isEmpty
        }

        /// - Complexity: O(n)
        public var actors: Set<Actor<Act>> {
            Set(self.refs.map { Actor<Act>(ref: $0) })
        }

        public func actor(named name: String) -> Actor<Act>? {
            self.refs.first { $0.address.name == name }.map { Actor<Act>(ref: $0) }
        }

        public var first: Actor<Act>? {
            self.refs.first.map { Actor<Act>(ref: $0) }
        }
    }
}
