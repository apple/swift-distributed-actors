//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

/// System-wide receptionist, used to register and look up actors by keys they register with.
///
/// Receptionists are designed to work seamlessly offer the same capability local and distributed.
///
/// - SeeAlso: `_ActorContext<Message>.Receptionist`, accessible in the `_Behavior` style API via `context.receptionist`.
internal struct SystemReceptionist: _BaseReceptionistOperations {
    let ref: _ActorRef<Receptionist.Message>

    init(ref receptionistRef: _ActorRef<Receptionist.Message>) {
        self.ref = receptionistRef
    }

    @discardableResult
    public func register<Guest>(
        _ guest: Guest,
        as id: String,
        replyTo: _ActorRef<_Reception.Registered<Guest>>? = nil
    ) -> _Reception.Key<Guest> where Guest: _ReceptionistGuest {
        let key: _Reception.Key<Guest> = _Reception.Key(Guest.self, id: id)
        self.register(guest, with: key, replyTo: replyTo)
        return key
    }

    @discardableResult
    public func register<Guest>(
        _ guest: Guest,
        with key: _Reception.Key<Guest>,
        replyTo: _ActorRef<_Reception.Registered<Guest>>? = nil
    ) -> _Reception.Key<Guest> where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Register<Guest>(guest, key: key, replyTo: replyTo))
        return key
    }

    public func lookup<Guest>(
        _ key: _Reception.Key<Guest>,
        replyTo: _ActorRef<_Reception.Listing<Guest>>,
        timeout: Duration = .effectivelyInfinite
    ) where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Lookup<Guest>(key: key, replyTo: replyTo))
    }

    public func subscribe<Guest>(
        _ subscriber: _ActorRef<_Reception.Listing<Guest>>,
        to key: _Reception.Key<Guest>
    ) where Guest: _ReceptionistGuest {
        self.ref.tell(Receptionist.Subscribe<Guest>(key: key, subscriber: subscriber))
    }
}
