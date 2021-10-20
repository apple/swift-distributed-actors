//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed

extension AnyActorIdentity {
    var _unwrapActorAddress: ActorAddress? {
        self.underlying as? ActorAddress
    }

    var _forceUnwrapActorAddress: ActorAddress {
        guard let address = self._unwrapActorAddress else {
            fatalError("""
                       Cannot unwrap \(ActorAddress.self) from \(Self.self). 
                       Cluster currently does not support any other ActorIdentity types.
                       Underlying type was: \(type(of: self.underlying))
                       """)
        }

        return address
    }
}

extension ActorTransport {
    var _unwrapActorSystem: ActorSystem? {
        self as? ActorSystem
    }

    var _forceUnwrapActorSystem: ActorSystem {
        guard let system = self._unwrapActorSystem else {
            fatalError("""
                       Cannot unwrap \(ActorSystem.self) from \(Self.self). 
                       Cluster does not support mixing transports. Instance was: \(self) 
                       """)
        }

        return system
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Type erasers

@usableFromInline
struct AnyDistributedActor: Sendable, Hashable {
    @usableFromInline
    let underlying: DistributedActor

    @usableFromInline
    init<Act: DistributedActor>(_ actor: Act) {
        self.underlying = actor
    }

    @usableFromInline
    var id: AnyActorIdentity {
        underlying.id
    }

    @usableFromInline
    var actorTransport: ActorTransport {
        underlying.actorTransport
    }
    @usableFromInline
    func `force`<T: DistributedActor>(as _: T.Type) -> T {
        underlying as! T
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        underlying.id.hash(into: &hasher)
    }

    @usableFromInline
    static func ==(lhs: AnyDistributedActor, rhs: AnyDistributedActor) -> Bool {
        lhs.id == rhs.id
    }
}

extension DistributedActor {
    nonisolated var asAnyDistributedActor: AnyDistributedActor {
        AnyDistributedActor(self)
    }
}

distributed actor StubDistributedActor {
    // TODO: this is just to prevent a DI crash because of enums without cases and Codable
    distributed func _noop() {}
}

