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

/// A dictionary which only weakly retains the
public struct WeakActorDictionary<Act: DistributedActor>: ExpressibleByDictionaryLiteral
    where Act.ID == ClusterSystem.ActorID
{
    var underlying: [ClusterSystem.ActorID: DistributedActorRef.Weak<Act>]

    /// Initialize an empty dictionary.
    public init() {
        self.underlying = [:]
    }

    public init(dictionaryLiteral elements: (Act.ID, Act)...) {
        var dict: [ClusterSystem.ActorID: DistributedActorRef.Weak<Act>] = [:]
        dict.reserveCapacity(elements.count)
        for (id, actor) in elements {
            dict[id] = .init(actor)
        }
        self.underlying = dict
    }

    /// Insert the passed in actor into the dictionary.
    ///
    /// Note that the dictionary only holds the actor weakly,
    /// so if no other strong references to the actor remain this dictionary
    /// will not contain the actor anymore.
    ///
    /// - Parameter actor:
    public mutating func insert(_ actor: Act) {
        self.underlying[actor.id] = DistributedActorRef.Weak(actor)
    }

    public mutating func getActor(identifiedBy id: ClusterSystem.ActorID) -> Act? {
        guard let ref = underlying[id] else {
            // unknown id
            return nil
        }

        guard let knownActor = ref.actor else {
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
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Weak distributed actor reference wrapper helpers

enum DistributedActorRef {

    /// Wrapper class for weak `distributed actor` references.
    ///
    /// Allows for weak storage of distributed actor references inside collections,
    /// although those collections need to be manually cleared from dead references.
    ///
    public final class Weak<Act: DistributedActor>: CustomStringConvertible {
        private weak var weakRef: Act?

        public init(_ actor: Act) {
            self.weakRef = actor
        }

        public var actor: Act? {
            self.weakRef
        }

        public var description: String {
            let isLocalStr: String
            if let actor = self.actor {
                isLocalStr = "\(__isLocalActor(actor))"
            } else {
                isLocalStr = "unknown/released"
            }

            return "DistributedActorRef.Weak(\(self.actor, orElse: "nil"), isLocal: \(isLocalStr))"
        }
    }

    /// Wrapper class for weak `distributed actor` references.
    ///
    /// Allows for weak storage of distributed actor references inside collections,
    /// although those collections need to be manually cleared from dead references.
    ///
    public final class WeakWhenLocal<Act: DistributedActor>: CustomStringConvertible {
        private weak var weakLocalRef: Act?
        private let remoteRef: Act?

        public init(_ actor: Act) {
            if __isRemoteActor(actor) {
                self.remoteRef = actor
                self.weakLocalRef = nil
            } else {
                self.remoteRef = nil
                self.weakLocalRef = actor
            }

            assert((self.remoteRef == nil && self.weakLocalRef != nil) ||
                    (self.remoteRef != nil && self.weakLocalRef == nil),
                    "Only a single var may hold the actor: remote: \(self.remoteRef, orElse: "nil"), \(self.weakLocalRef, orElse: "nil")")
        }

        public var actor: Act? {
            remoteRef ?? weakLocalRef
        }

        public var description: String {
            "DistributedActorRef.WeakWhenLocal(\(self.actor, orElse: "nil"), isLocal: \(self.remoteRef == nil))"
        }
    }

}