//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context Receptionist

extension ActorContext {
    /// Receptionist wrapper, offering convenience functions for registering _this_ actor with the receptionist.
    ///
    /// - SeeAlso: `DistributedActors.Receptionist`, for the system wide receptionist API
    /// - SeeAlso: `Actor<M>.Receptionist`, for the receptionist wrapper specific to actorable actors
    public var receptionist: ActorContext<Message>.Receptionist {
        Self.Receptionist(system: self.system, context: self)
    }
}

extension ActorContext {
    /// The receptionist enables type-safe and dynamic (subscription based) actor discovery.
    ///
    /// Actors may register themselves when they start with an `Reception.Key<A>`
    ///
    /// - SeeAlso: `DistributedActors.Receptionist` for the `ActorRef<Message>` version of this API.
    public struct Receptionist {
        let system: ActorSystem
        let context: ActorContext<Message>

        public init(system: ActorSystem, context: ActorContext<Message>) {
            self.system = system
            self.context = context
        }

        /// Registers `myself` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func registerMyself(as id: String) {
            self.registerMyself(with: .init(messageType: Message.self, id: id))
        }

        /// Registers `myself` in the systems receptionist with given key.
        public func registerMyself(with key: SystemReceptionist.RegistrationKey<Message>) {
            self.register(self.context.myself, key: key)
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".
        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<M>(_ ref: ActorRef<M>, as id: String) where M: Codable {
            self.register(ref, key: .init(messageType: M.self, id: id))
        }

        /// Registers passed in `actor` in the systems receptionist with given id.
        ///
        /// - Parameters:
        ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
        public func register<M>(_ ref: ActorRef<M>, key: SystemReceptionist.RegistrationKey<M>) where M: Codable {
            self.system.receptionist.register(ref, key: key)
        }

        /// Subscribe to changes in checked-in actors under given `key`.
        ///
        /// The `subscriber` actor will be notified with `Receptionist.Listing<M>` messages when new actors register, leave or die, under the passed in key.
        func subscribe<M>(key: SystemReceptionist.RegistrationKey<M>, subscriber: ActorRef<SystemReceptionist.Listing<M>>) {
            self.system.receptionist.subscribe(key: key, subscriber: subscriber)
        }

        /// Perform a single lookup for an `ActorRef<M>` identified by the passed in `key`.
        ///
        /// - Parameters:
        ///   - key: selects which actors we are interested in.
        public func lookup<M>(_ key: SystemReceptionist.RegistrationKey<M>, timeout: TimeAmount) -> AskResponse<SystemReceptionist.Listing<M>> {
            self.system.receptionist.lookup(key: key, timeout: timeout)
        }
    }

}