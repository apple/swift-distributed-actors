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

import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Type erasers

@usableFromInline
struct AnyDistributedActor: Sendable, Hashable {
    @usableFromInline
    let underlying: any DistributedActor

    @usableFromInline
    init<Act: DistributedActor>(_ actor: Act) where Act.ActorSystem == ClusterSystem {
        self.underlying = actor
    }

    @usableFromInline
    var id: ClusterSystem.ActorID {
        self.underlying.id as! ActorID // FIXME: could remove this entire wrapper?
    }

    @usableFromInline
    var actorSystem: ClusterSystem {
        self.underlying.actorSystem as! ClusterSystem
    }

    @usableFromInline
    func force<T: DistributedActor>(as _: T.Type) -> T {
        // FIXME: hack, instead just store the id then?
        if let resolved = try? T.resolve(id: underlying.id as! T.ID, using: underlying.actorSystem as! T.ActorSystem) {
            return resolved
        }

        return fatalErrorBacktrace("Failed to cast [\(self.underlying)]\(reflecting: type(of: self.underlying)) or resolve \(self.underlying.id) as \(reflecting: T.self)")
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        self.underlying.id.hash(into: &hasher)
    }

    @usableFromInline
    static func == (lhs: AnyDistributedActor, rhs: AnyDistributedActor) -> Bool {
        lhs.id == rhs.id
    }
}

extension DistributedActor where ActorSystem == ClusterSystem {
    nonisolated var asAnyDistributedActor: AnyDistributedActor {
        AnyDistributedActor(self)
    }
}

internal distributed actor StubDistributedActor {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem
}
