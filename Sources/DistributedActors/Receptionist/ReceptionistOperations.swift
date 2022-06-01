//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation // String.replacingOccurrences ...
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: General _ReceptionistOperations

/// Specifically to be implemented ONLY by `system.receptionist` i.e. the `SystemReceptionist`.
internal protocol _BaseReceptionistOperations {
    /// Registers passed in `actor` in the systems receptionist with given id.
    ///
    /// - Parameters:
    ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".
    ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
    @discardableResult
    func register<Guest>(
        _ guest: Guest,
        as id: String,
        replyTo: _ActorRef<Reception.Registered<Guest>>?
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest

    /// Registers passed in `actor` in the systems receptionist with given id.
    ///
    /// - Parameters:
    ///   - actor: the actor to register with the receptionist. It may be `context.myself` or any other actor, however generally it is recommended to let actors register themselves when they are "ready".        ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group, the recommended id is "sensors".
    @discardableResult
    func register<Guest>(
        _ guest: Guest,
        with key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Registered<Guest>>?
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest

    /// Subscribe to changes in checked-in actors under given `key`.
    ///
    /// The `subscriber` actor will be notified with `Reception.Listing<M>` messages when new actors register, leave or die, under the passed in key.
    func subscribe<Guest>(
        _ subscriber: _ActorRef<Reception.Listing<Guest>>,
        to key: Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest

    /// Perform a *single* lookup for an actor identified by the passed in `key`.
    ///
    /// - Parameters:
    ///   - key: selects which actors we are interested in.
    func lookup<Guest>(
        _ key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Listing<Guest>>,
        timeout: TimeAmount
    ) where Guest: _ReceptionistGuest
}

internal protocol _ReceptionistOperations: _BaseReceptionistOperations {
    var _system: ClusterSystem { get }
}

extension _ReceptionistOperations {
    @inlinable
    @discardableResult
    internal func register<Guest>(
        _ guest: Guest,
        as id: String,
        replyTo: _ActorRef<Reception.Registered<Guest>>? = nil
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest {
        self.register(guest, with: .init(Guest.self, id: id), replyTo: replyTo)
    }

    @inlinable
    @discardableResult
    internal func register<Guest>(
        _ guest: Guest,
        with key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Registered<Guest>>? = nil
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest {
        self._system._receptionist.register(guest, with: key, replyTo: replyTo)
    }

    @inlinable
    internal func subscribe<Guest>(
        _ subscriber: _ActorRef<Reception.Listing<Guest>>,
        to key: Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest {
        self._system._receptionist.subscribe(subscriber, to: key)
    }

    @inlinable
    internal func lookup<Guest>(
        _ key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Listing<Guest>>,
        timeout: TimeAmount = .effectivelyInfinite
    ) where Guest: _ReceptionistGuest {
        self._system._receptionist.lookup(key, replyTo: replyTo, timeout: timeout)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: MyselfSpecificReceptionistOperations

internal protocol _MyselfReceptionistOperations: _ReceptionistOperations {
    associatedtype Message: Codable
    associatedtype Myself: _ReceptionistGuest

    // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
    var _myself: Myself { get }
    // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
    var _underlyingContext: _ActorContext<Message> { get }

    /// Registers `myself` in the systems receptionist with given key.
    @discardableResult
    func registerMyself(
        with key: Reception.Key<Myself>,
        replyTo: _ActorRef<Reception.Registered<Myself>>?
    ) -> Reception.Key<Myself>

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
    ///   - callback: invoked whenever actors join/leave the reception or when they terminate.
    ///               The invocation is made on the owning actor's context, meaning that it is safe to mutate actor state from the callback.
    func subscribeMyself<Guest>(
        to key: Reception.Key<Guest>,
        subReceive callback: @escaping (Reception.Listing<Guest>) -> Void
    ) where Guest: _ReceptionistGuest

    /// Subscribe this actor to actors registering under given `key`.
    ///
    /// A new `Reception.Listing<Guest>` is emitted whenever new actors join (or leave) the reception.
    ///
    /// - SeeAlso: `subscribeMyself(to:subReceive:)`
    func subscribeMyself<Guest>(
        to key: Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest, Myself.Message == Reception.Listing<Guest>
}

extension _MyselfReceptionistOperations {
    @inlinable
    @discardableResult
    internal func registerMyself(
        with key: Reception.Key<Myself>,
        replyTo: _ActorRef<Reception.Registered<Myself>>? = nil
    ) -> Reception.Key<Myself> {
        self.register(self._myself, with: key, replyTo: replyTo)
        return key
    }

    @inlinable
    internal func subscribeMyself<Guest>(
        to key: Reception.Key<Guest>,
        subReceive callback: @escaping (Reception.Listing<Guest>) -> Void
    ) where Guest: _ReceptionistGuest {
        let subReceiveStringID = "subscribe-\(Guest.self)"
        let id = _SubReceiveId<Reception.Listing<Guest>>(id: subReceiveStringID)
        let subRef = self._underlyingContext
            .subReceive(id, Reception.Listing<Guest>.self) { listing in
                callback(listing)
            }

        self._underlyingContext.receptionist.subscribe(subRef, to: key)
    }

    @inlinable
    internal func subscribeMyself<Guest>(
        to key: Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest, Myself.Message == Reception.Listing<Guest> {
        self.subscribe(self._myself._ref, to: key)
    }
}
