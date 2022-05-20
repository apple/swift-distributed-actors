//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

struct WeakActorDictionary {
    var underlying: [ClusterSystem.ActorID: WeakDistributedActorContainer] = [:]

    final class WeakDistributedActorContainer {
        weak var actor: (any DistributedActor)?

        init<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {
            self.actor = actor
        }

        init(idForRemoval id: ClusterSystem.ActorID) {
            self.actor = nil
        }
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
            self.removeActor(identifiedBy: id)
            return nil
        }

        return knownActor
    }
}
