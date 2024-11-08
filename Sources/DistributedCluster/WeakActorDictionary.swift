//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

/// A dictionary which only weakly retains the
public struct WeakActorDictionary<Act: DistributedActor>: ExpressibleByDictionaryLiteral
    where Act.ID == ClusterSystem.ActorID
{
    var underlying: [ClusterSystem.ActorID: WeakContainer]

    final class WeakContainer {
        weak var actor: Act?

        init(_ actor: Act) {
            self.actor = actor
        }

//        init(idForRemoval id: ClusterSystem.ActorID) {
//            self.actor = nil
//        }
    }

    /// Initialize an empty dictionary.
    public init() {
        self.underlying = [:]
    }

    public init(dictionaryLiteral elements: (Act.ID, Act)...) {
        self.underlying = [:]
        self.underlying.reserveCapacity(elements.count)
        for (id, actor) in elements {
            self.underlying[id] = .init(actor)
        }
    }

    /// Insert the passed in actor into the dictionary.
    ///
    /// Note that the dictionary only holds the actor weakly,
    /// so if no other strong references to the actor remain this dictionary
    /// will not contain the actor anymore.
    ///
    /// - Parameter actor:
    public mutating func insert(_ actor: Act) {
        self.underlying[actor.id] = WeakContainer(actor)
    }

    public mutating func getActor(identifiedBy id: ClusterSystem.ActorID) -> Act? {
        guard let container = underlying[id] else {
            // unknown id
            return nil
        }

        guard let knownActor = container.actor else {
            // the actor was released -- let's remove the container while we're here
            _ = self.removeActor(identifiedBy: id)
            return nil
        }

        return knownActor
    }

    public mutating func removeActor(identifiedBy id: ClusterSystem.ActorID) -> Act? {
        return self.underlying.removeValue(forKey: id)?.actor
    }
}

public struct WeakAnyDistributedActorDictionary {
    var underlying: [ClusterSystem.ActorID: WeakDistributedActorContainer]

    final class WeakDistributedActorContainer {
        weak var actor: (any DistributedActor)?

        init<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {
            self.actor = actor
        }

        init(idForRemoval id: ClusterSystem.ActorID) {
            self.actor = nil
        }
    }

    public init() {
        self.underlying = [:]
    }

    mutating func removeActor(identifiedBy id: ClusterSystem.ActorID) -> Bool {
        return self.underlying.removeValue(forKey: id) != nil
    }

    mutating func insert<Act: DistributedActor>(actor: Act) where Act.ID == ClusterSystem.ActorID {
        self.underlying[actor.id] = .init(actor)
    }

    mutating func get(identifiedBy id: ClusterSystem.ActorID) -> (any DistributedActor)? {
        guard let container = underlying[id] else {
            // unknown id
            return nil
        }

        guard let knownActor = container.actor else {
            // the actor was released -- let's remove the container while we're here
            _ = self.removeActor(identifiedBy: id)
            return nil
        }

        return knownActor
    }
}

final class Weak<Act: DistributedActor> {
    weak var actor: Act?

    init(_ actor: Act) {
        self.actor = actor
    }

    init(idForRemoval id: ClusterSystem.ActorID) {
        self.actor = nil
    }
}
