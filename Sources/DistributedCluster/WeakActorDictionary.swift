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
public struct WeakLocalRefDictionary<Act: DistributedActor>: ExpressibleByDictionaryLiteral
where Act.ID == ClusterSystem.ActorID {
    var underlying: [ClusterSystem.ActorID: WeakLocalRef<Act>]

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
    public mutating func insert(_ actor: Act) {
        self.underlying[actor.id] = WeakLocalRef(actor)
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
        self.underlying.removeValue(forKey: id)?.actor
    }
}

public struct WeakAnyDistributedActorDictionary {
    var underlying: [ClusterSystem.ActorID: WeakDistributedActorContainer]

    final class WeakDistributedActorContainer {
        weak var actor: (any DistributedActor)?

        init<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {
            self.actor = actor
        }
    }

    public init() {
        self.underlying = [:]
    }

    mutating func removeActor(identifiedBy id: ClusterSystem.ActorID) -> Bool {
        self.underlying.removeValue(forKey: id) != nil
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

/// Distributed actor reference helper which avoids strongly retaining local actors,
/// in order no to accidentally extend their lifetimes. Specifically very useful
/// when designing library code which should NOT keep user-actors alive, and should
/// work with remote and local actors in the same way.
///
/// The reference is *weak* when the actor is **local**,
/// in order to not prevent the actor from being deallocated when all **other**
/// references to it are released.
///
/// The reference is *strong* when referencing a **remote** distributed actor,
/// a strong reference to a remote actor does not necessarily keep it alive,
/// however it allows keeping `weak var` references to remote distributed actors
/// without them being immediately released if they were obtained from a `resolve`
/// call for example -- as by design, no-one else will be retaining them, there
/// is a risk of always observing an immediately released reference.
///
/// Rather than relying on reference counting for remote references, utilize the
/// `LifecycleWatch/watchTermination(of:)` lifecycle monitoring method. This
/// mechanism will invoke an actors ``LifecycleWatch/actorTerminated(_:)` when
/// the remote actor has terminated and we should clean it up locally.
///
/// Generally, the pattern should be to store actor references local-weakly
/// when we "don't want to keep them alive" on behalf of the user, and at the
/// same time always use ``LifecycleMonitoring`` for handling their lifecycle -
/// regardless if the actor is local or remote, lifecycle monitoring behaves
/// in the expected way.
final class WeakLocalRef<Act: DistributedActor>: Hashable where Act.ID == ClusterSystem.ActorID {
    let id: Act.ID

    private weak var weakLocalRef: Act?
    private let strongRemoteRef: Act?

    var actor: Act? {
        self.strongRemoteRef ?? self.weakLocalRef
    }

    init(_ actor: Act) {
        if isDistributedKnownRemote(actor) {
            self.weakLocalRef = nil
            self.strongRemoteRef = actor
        } else {
            self.weakLocalRef = actor
            self.strongRemoteRef = nil
        }
        self.id = actor.id
    }

    init(forRemoval id: ClusterSystem.ActorID) {
        self.weakLocalRef = nil
        self.strongRemoteRef = nil
        self.id = id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }

    static func == (lhs: WeakLocalRef<Act>, rhs: WeakLocalRef<Act>) -> Bool {
        if lhs === rhs {
            return true
        }
        if lhs.id != rhs.id {
            return false
        }
        return true
    }
}

@_silgen_name("swift_distributed_actor_is_remote")
internal func isDistributedKnownRemote(_ actor: AnyObject) -> Bool
