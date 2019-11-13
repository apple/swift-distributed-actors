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

        public static func key<Act: Actorable>(_ type: Act.Type = Act.self, id: String) -> SystemReceptionist.RegistrationKey<Act.Message> {
            SystemReceptionist.RegistrationKey(Act.Message.self, id: id)
        }

        /// Registers `myself` in the systems receptionist with given group id.
        public func register(as id: String) {
            self.register(actor: self.context.myself, using: Receptionist.key(A.self, id: id))
        }

        public func register<Act: Actorable>(actor: Actor<Act>, using key: SystemReceptionist.RegistrationKey<Act.Message>) {
            self.underlying.system.receptionist.register(actor.ref, key: key)
        }

        // TODO: this is a prime example what we need task for.. we'd need to emit some value, or many ones, and make it safe to call

        // could return Combine.Publisher or our MultiTask? if we could make it safe inside the actor context
        // TODO: abusing the registration key somewhat; it was intended to be message
        public func subscribe<Act: Actorable>(_ type: Act.Type = Act.self, _ key: SystemReceptionist.RegistrationKey<Act.Message>, onListingChange: @escaping (Reception.Listing<Act>) -> Void) {
            self.underlying.system.receptionist.subscribe(
                key: key,
                subscriber: self.underlying.subReceive("subscribe-\(key)", SystemReceptionist.Listing<Act.Message>.self) { listing in
                    let actors = Set(listing.refs.map { ref in
                        Actor<Act>(ref: ref)
                    })
                    onListingChange(.init(actors: actors))
                }
            )
        }

        public func lookup<Act: Actorable>(_: Act.Type = Act.self, _ key: SystemReceptionist.RegistrationKey<Act.Message>) -> EventLoopFuture<Reception.Listing<Act>> {
            let promise = self.context.system._eventLoopGroup.next().makePromise(of: Reception.Listing<Act>.self)
            self.underlying.system.receptionist.tell(SystemReceptionist.Lookup(
                key: key,
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
    /// Actorable version of `SystemReceptionist.Listing`, allowing location of `Actor` instances.
    public struct Listing<A: Actorable> {
        public let actors: Set<Actor<A>>

        public var isEmpty: Bool {
            self.actors.isEmpty
        }
    }
}
