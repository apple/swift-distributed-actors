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

extension ActorContext {
    /// Receptionist wrapper, offering convenience functions for registering _this_ actor with the receptionist.
    ///
    /// - SeeAlso: `DistributedActors.Receptionist`, for the system wide receptionist API
    /// - SeeAlso: `Actor<M>.Receptionist`, for the receptionist wrapper specific to actorable actors
    public var receptionist: ActorContext<Message>.Receptionist {
        Self.Receptionist(context: self)
    }
}

extension ActorContext {
    /// The receptionist enables type-safe and dynamic (subscription based) actor discovery.
    ///
    /// Actors may register themselves when they start with an `Reception.Key<A>`
    ///
    /// - SeeAlso: `DistributedActors.Receptionist` for the `ActorRef<Message>` version of this API.
    public struct Receptionist: MyselfReceptionistOperations {
        public typealias Myself = ActorRef<Message>

        public let _underlyingContext: ActorContext<Message>

        public var _myself: Myself {
            self._underlyingContext.myself
        }

        public var _system: ActorSystem {
            self._underlyingContext.system
        }

        public init(context: ActorContext<Message>) {
            self._underlyingContext = context
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: ActorContext<Message> specific convenience functions

        /// Subscribe to changes in checked-in actors under given `key` by with a subReceive.
        ///
        /// The sub receive (created using `context.subReceive`) is always executed on the actor's context and thus it is
        /// thread-safe to mutate any of the actors state from this callback.
        @inlinable
        public func subscribeMyself<Guest>(
            to key: Reception.Key<Guest>,
            subReceive: @escaping (Reception.Listing<Guest>) -> Void
        ) where Guest: ReceptionistGuest {
            let ref = self._underlyingContext.subReceive(Reception.Listing<Guest>.self, subReceive)
            self._system._receptionist.subscribe(ref, to: key)
        }
    }
}
