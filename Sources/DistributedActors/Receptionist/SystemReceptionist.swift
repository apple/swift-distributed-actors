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

import Logging

/// System-wide receptionist, used to register and look up actors by keys they register with.
///
/// Receptionists are designed to work seamlessly offer the same capability local and distributed.
///
/// - SeeAlso: `_ActorContext<Message>.Receptionist`, accessible in the `Behavior` style API via `context.receptionist`.
/// - SeeAlso: `Actor<Act>.Context.Receptionist`, accessible in the `Actorable` style API via `context.receptionist`.
public struct SystemReceptionist: BaseReceptionistOperations {
    let ref: _ActorRef<Receptionist.Message>

    init(ref receptionistRef: _ActorRef<Receptionist.Message>) {
        self.ref = receptionistRef
    }

    @discardableResult
    public func register<Guest>(
        _ guest: Guest,
        as id: String,
        replyTo: _ActorRef<Reception.Registered<Guest>>? = nil
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest {
        let key: Reception.Key<Guest> = Reception.Key(Guest.self, id: id)
        self.register(guest, with: key, replyTo: replyTo)
        return key
    }

    @discardableResult
    public func register<Guest>(
        _ guest: Guest,
        with key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Registered<Guest>>? = nil
    ) -> Reception.Key<Guest> where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Register<Guest>(guest, key: key, replyTo: replyTo))
        return key
    }

    public func lookup<Guest>(
        _ key: Reception.Key<Guest>,
        timeout: TimeAmount = .effectivelyInfinite
    ) -> AskResponse<Reception.Listing<Guest>> where Guest: _ReceptionistGuest {
        self.ref.ask(for: Reception.Listing<Guest>.self, timeout: timeout) {
            Receptionist.Lookup<Guest>(key: key, replyTo: $0)
        }
    }

    public func lookup<Guest>(
        _ key: Reception.Key<Guest>,
        replyTo: _ActorRef<Reception.Listing<Guest>>,
        timeout: TimeAmount = .effectivelyInfinite
    ) where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Lookup<Guest>(key: key, replyTo: replyTo))
    }

    public func subscribe<Guest>(
        _ subscriber: _ActorRef<Reception.Listing<Guest>>,
        to key: Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Subscribe<Guest>(key: key, subscriber: subscriber))
    }
}
