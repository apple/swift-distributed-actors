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

import Foundation
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

    public struct Receptionist {
        let context: Myself.Context

        private var underlying: ActorContext<A.Message> {
            self.context.underlying
        }

        /// Registers `myself` in the systems receptionist with given group id.
        public func register(as id: String) {
            self.register(actor: self.context.myself, key: Reception.Key(A.self, id: id))
        }

        public func register<Act: Actorable>(actor: Actor<Act>, key: Reception.Key<Act>) {
            self.underlying.system.receptionist.register(actor.ref, key: key.underlying)
        }

        // TODO: this is a prime example what we need task for.. we'd need to emit some value, or many ones, and make it safe to call

        // could return Combine.Publisher or our MultiTask? if we could make it safe inside the actor context
        // TODO: abusing the registration key somewhat; it was intended to be message
        public func subscribe<Act: Actorable>(_ key: Reception.Key<Act>, onListingChange: @escaping (Reception.Listing<Act>) -> Void) {
            self.underlying.system.receptionist.subscribe(
                key: key.underlying,
                subscriber: self.underlying.subReceive("subscribe-\(key)", SystemReceptionist.Listing<Act.Message>.self) { listing in
                    let actors = Set(listing.refs.map { ref in
                        Actor<Act>(ref: ref)
                    })
                    onListingChange(.init(actors: actors))
                }
            )
        }

        public func ownedListing<Act: Actorable>(_ key: Reception.Key<Act>) -> ActorableOwned<Reception.Listing<Act>> {
            let owned: ActorableOwned<Reception.Listing<Act>> = ActorableOwned(self.context)
            self.context.system.receptionist.subscribe(
                key: key.underlying,
                subscriber: self.context.underlying.subReceive(SystemReceptionist.Listing<Act.Message>.self) { listing in
                    let actors = Set(listing.refs.map { ref in
                        Actor<Act>(ref: ref)
                    })
                    owned.update(newValue: Reception.Listing(actors: actors))
                }
            )

            return owned
        }

        public func lookup<Act: Actorable>(_ key: Reception.Key<Act>) -> EventLoopFuture<Reception.Listing<Act>> {
            let promise = self.context.system._eventLoopGroup.next().makePromise(of: Reception.Listing<Act>.self)
            self.underlying.system.receptionist.tell(SystemReceptionist.Lookup(
                key: key.underlying,
                replyTo: self.underlying.subReceive("lookup-\(key)", SystemReceptionist.Listing<Act.Message>.self) { listing in
                    let actors = Set(listing.refs.map { ref in
                        Actor<Act>(ref: ref)
                    })
                    promise.succeed(.init(actors: actors))
                }
            )
            )

            return promise.futureResult
        }
    }
}

public enum Reception {}

extension Reception {
    public struct Key<Act: Actorable> {
        public let underlying: SystemReceptionist.RegistrationKey<Act.Message>

        public init(_ type: Act.Type = Act.self, id: String) {
            self.underlying = .init(Act.Message.self, id: id)
        }

        public var id: String {
            self.underlying.id
        }
    }
}

extension Reception {
    /// Actorable version of `SystemReceptionist.Listing`, allowing location of `Actor` instances.
    public struct Listing<A: Actorable>: Equatable {
        public let actors: Set<Actor<A>>

        public var isEmpty: Bool {
            self.actors.isEmpty
        }

        var first: Actor<A>? {
            self.actors.first
        }
    }
}
