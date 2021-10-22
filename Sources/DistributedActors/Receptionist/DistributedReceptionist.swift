//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-distributed-actors open source project
//
// Copyright (c) 2018 Apple Inc. and the swift-distributed-actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-distributed-actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import Logging

/// A receptionist is a system actor that allows users to register actors under
/// a key to make them available to other parts of the system, without having to
/// share a reference with that specific part directly.
///
/// There are different reasons for using the receptionist over direct sharing
/// of references, e.g. parts of the system can be brought up independently and
/// then lookup the reference of another part once it's ready, or subscribe to
/// be notified once the other part has registered.
///
/// Actors usually register themselves with the receptionist as part of their setup process.
public protocol DistributedReceptionist
//        : Actor // FIXME(swift): ActorConformances cause us to crash here, will fix
{

    /// Registers passed in distributed actor in the systems receptionist with given id.
    ///
    /// - Parameters:
    ///   - guest: the actor to register with the receptionist.
    ///   - id: id used for the key identifier. E.g. when aiming to register all instances of "Sensor" in the same group,
    ///         the recommended id is "all/sensors".
    func register<Guest>(
            _ guest: Guest,
            with key: DistributedReception.Key<Guest>
            // TODO(distributed): should gain a "retain (or not)" version, the receptionist can keep alive actors, but sometimes we don't want that, it depends
    ) async where Guest: DistributedActor & __DistributedClusterActor

    /// Subscribe to changes in checked-in actors under given `key`.
    func subscribe<Guest>(to key: DistributedReception.Key<Guest>) async -> DistributedReception.GuestListing<Guest>
            where Guest: DistributedActor & __DistributedClusterActor

    /// Perform a *single* lookup for a distributed actor identified by the passed in `key`.
    ///
    /// - Parameters:
    ///   - key: selects which actors we are interested in.
    func lookup<Guest>(_ key: DistributedReception.Key<Guest>) async -> Set<Guest>
            where Guest: DistributedActor & __DistributedClusterActor

}

extension DistributedReception {
    public struct GuestListing<Guest: DistributedActor & __DistributedClusterActor>: AsyncSequence, Sendable {
        public typealias Element = Guest

        let receptionist: OpLogDistributedReceptionist
        let key: DistributedReception.Key<Guest>

        init(receptionist: OpLogDistributedReceptionist, key: DistributedReception.Key<Guest>) {
            self.receptionist = receptionist
            self.key = key
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(receptionist: receptionist, key: key)
        }

        public class AsyncIterator: AsyncIteratorProtocol {
            var underlying: AsyncStream<Element>.Iterator!

            init(receptionist __secretlyKnownToBeLocal: OpLogDistributedReceptionist, key: DistributedReception.Key<Guest>) {
                self.underlying = AsyncStream<Element> { continuation in
                    let anySubscribe = AnyDistributedReceptionListingSubscription(
                        subscriptionID: ObjectIdentifier(self),
                        key: key.asAnyKey,
                        onNext: { anyGuest in
                            switch continuation.yield(anyGuest.force(as: Guest.self)) {
                            case .terminated, .dropped:
                                continuation.finish()
                            case .enqueued:
                                () // ok
                            }
                    })

                    Task { // FIXME(swift): really would like for this to be send{} and not Task{}
                        await __secretlyKnownToBeLocal._subscribe(subscription: anySubscribe)
                    }

                    continuation.onTermination = { @Sendable termination -> Void in
                        Task {
                            await __secretlyKnownToBeLocal._cancelSubscription(subscription: anySubscribe)
                        }
                    }
                }.makeAsyncIterator()
            }

            public func next() async -> Element? {
                await underlying.next()
            }
        }
    }
}

/// Represents a registration of an actor with its (local) receptionist,
/// at the version represented by the `(seqNr, .uniqueNode(actor.<address>.uniqueNode))`.
///
/// This allows a local subscriber to definitely compare a registration with its "already seen"
/// version vector (that contains versions for every node it is receiving updates from),
/// and only emit those to the user-facing stream which have not been observed yet.
internal struct VersionedRegistration: Hashable {
    let version: VersionVector
    let actor: AnyDistributedActor

    init(remoteOpSeqNr: UInt64, actor: AnyDistributedActor) {
        let address = actor.id._forceUnwrapActorAddress
        self.version = VersionVector(remoteOpSeqNr, at: .uniqueNode(address.uniqueNode))
        self.actor = actor
    }

    init(forRemovalOf actor: AnyDistributedActor) {
        self.version = .empty
        self.actor = actor
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(actor)
    }

    static func ==(lhs: VersionedRegistration, rhs: VersionedRegistration) -> Bool {
        if lhs.actor != rhs.actor {
            return false
        }
        return true
    }
}

internal final class DistributedReceptionistStorage {
    typealias ReceptionistOp = OpLogDistributedReceptionist.ReceptionistOp

    internal var _registrations: [AnyDistributedReceptionKey: Set<VersionedRegistration>] = [:]
    internal var _subscriptions: [AnyDistributedReceptionKey: Set<AnyDistributedReceptionListingSubscription>] = [:]

    /// Per (receptionist) node mapping of which keys are presently known to this receptionist on the given node.
    /// This is used to perform quicker cleanups upon a node/receptionist crashing, and thus all existing references
    /// on that node should be removed from our storage.
    private var _registeredKeysByNode: [UniqueNode: Set<AnyDistributedReceptionKey>] = [:]

    /// Allows for reverse lookups, when an actor terminates, we know from which registrations to remove it from.
    internal var _identityToRegisteredKeys: [AnyActorIdentity: Set<AnyDistributedReceptionKey>] = [:]

    // ==== --------------------------------------------------------------------------------------------------------
    // MARK: Registrations

    /// This function ONLY operates on `.register` operations, and fails otherwise.
    ///
    /// - returns: `true` if the value was a newly inserted value, `false` otherwise
    func addRegistration<Guest>(sequenced: OpLog<ReceptionistOp>.SequencedOp,
                                key: AnyDistributedReceptionKey,
                                guest: Guest) -> Bool
            where Guest: DistributedActor & __DistributedClusterActor {
        guard sequenced.op.isRegister else {
            fatalError("\(#function) can only be called with .register operations, was: \(sequenced)")
        }

        guard let address = guest.id._unwrapActorAddress else {
            return false
        }
        self.addGuestKeyMapping(identity: guest.id, key: key)
        self.storeRegistrationNodeRelation(key: key, node: address.uniqueNode)

        let versionedRegistration = VersionedRegistration(
            remoteOpSeqNr: sequenced.sequenceRange.max,
            actor: guest.asAnyDistributedActor
        )
        return self.addTo(dict: &self._registrations, key: key, value: versionedRegistration)
    }

    func removeRegistration<Guest>(key: AnyDistributedReceptionKey, guest: Guest) -> Set<VersionedRegistration>?
            where Guest: DistributedActor & __DistributedClusterActor {
        let address = guest.id._forceUnwrapActorAddress

        _ = self.removeFromKeyMappings(guest.asAnyDistributedActor)
        self.removeSingleRegistrationNodeRelation(key: key, node: address.uniqueNode)

        let versionedRegistration = VersionedRegistration(
            forRemovalOf: guest.asAnyDistributedActor
        )
        return self.removeFrom(dict: &self._registrations, key: key, value: versionedRegistration)
    }

    func registrations(forKey key: AnyDistributedReceptionKey) -> Set<VersionedRegistration>? {
        self._registrations[key]
    }

    private func storeRegistrationNodeRelation(key: AnyDistributedReceptionKey, node: UniqueNode?) {
        if let node = node {
            self._registeredKeysByNode[node, default: []].insert(key)
        }
    }

    private func removeSingleRegistrationNodeRelation(key: AnyDistributedReceptionKey, node: UniqueNode?) {
        // FIXME: Implement me (!), we need to make the storage a counter
        //        and decrement here by one; once the counter reaches zero we know there is no more relationship
        //        and we can prune this key/node relationship
    }

    // ==== --------------------------------------------------------------------------------------------------------
    // MARK: Subscriptions

    func addSubscription(key: AnyDistributedReceptionKey, subscription: AnyDistributedReceptionListingSubscription) -> Bool {
        self.addTo(dict: &self._subscriptions, key: key, value: subscription)
    }

    @discardableResult
    func removeSubscription(key: AnyDistributedReceptionKey, subscription: AnyDistributedReceptionListingSubscription) -> Set<AnyDistributedReceptionListingSubscription>? {
        self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
    }

    func subscriptions(forKey key: AnyDistributedReceptionKey) -> Set<AnyDistributedReceptionListingSubscription>? {
        self._subscriptions[key]
    }

    /// - Returns: keys that this actor was REGISTERED under, and thus listings associated with it should be updated
    func removeFromKeyMappings(identity: AnyActorIdentity) -> RefMappingRemovalResult {
        guard var registeredUnderKeys = self._identityToRegisteredKeys.removeValue(forKey: identity) else {
            // was not registered under any keys before
            return RefMappingRemovalResult(registeredUnderKeys: [])
        }

        return RefMappingRemovalResult(registeredUnderKeys: registeredUnderKeys)
    }

    /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
    func removeFromKeyMappings(_ ref: AnyDistributedActor) -> RefMappingRemovalResult {
        guard let associatedKeys = self._identityToRegisteredKeys.removeValue(forKey: ref.id) else {
            return RefMappingRemovalResult(registeredUnderKeys: [])
        }

        var registeredKeys: Set<AnyDistributedReceptionKey> = [] // TODO: OR we store it directly as registeredUnderKeys/subscribedToKeys in the dict
        for key in associatedKeys {
            if self._registrations[key]?.remove(.init(forRemovalOf: ref)) != nil {
                _ = registeredKeys.insert(key)
            }
        }

        return RefMappingRemovalResult(registeredUnderKeys: registeredKeys)
    }

    struct RefMappingRemovalResult {
        /// The (now removed) ref was registered under the following keys
        let registeredUnderKeys: Set<AnyDistributedReceptionKey>
    }

    /// Prunes any registrations and subscriptions of the presence of any actors on the passed in `node`.
    ///
    /// - Returns: A result containing all keys which were changed by this operation (which previously contained nodes on this node),
    ///   as well as which local subscribers we need to notify about the change, even if _now_ they do not subscribe to anything anymore
    ///   (as they only were interested on things on the now-removed node). This allows us to eagerly and "in batch" give them a listing update
    ///   *once* with all the remote actors removed, rather than trickling in the changes to the Listing one by one (as it would be the case
    ///   if we waited for Terminated signals to trickle in and handle these removals one by one then).
    func pruneNode(_ node: UniqueNode) -> PrunedNodeDirective {
        var prune = PrunedNodeDirective()

        guard let keys = self._registeredKeysByNode[node] else {
            // no keys were related to this node, we should have nothing to clean-up here
            return prune
        }

        // for every key that was related to the now terminated node
        for key in keys {
            // 1) we remove any registrations that it hosted
            let registrations = self._registrations.removeValue(forKey: key) ?? []
            let remainingRegistrations = registrations.filter { registration in
                registration.actor.id._forceUnwrapActorAddress.uniqueNode != node
            }
            if !remainingRegistrations.isEmpty {
                self._registrations[key] = remainingRegistrations
            }
        }

        return prune
    }

    struct PrunedNodeDirective {
        fileprivate var changed: [AnyDistributedReceptionKey: Set<AnyDistributedReceptionListingSubscription>] = [:]

        var keys: Dictionary<AnyDistributedReceptionKey, Set<AnyDistributedReceptionListingSubscription>>.Keys {
            self.changed.keys
        }

        func peersToNotify(_ key: AnyDistributedReceptionKey) -> Set<AnyDistributedReceptionListingSubscription> {
            self.changed[key] ?? []
        }
    }

    /// - returns: `true` if the value was a newly inserted value, `false` otherwise
    private func addTo<Value: Hashable>(dict: inout [AnyDistributedReceptionKey: Set<Value>], key: AnyDistributedReceptionKey, value: Value) -> Bool {
        guard !(dict[key]?.contains(value) ?? false) else {
            return false
        }

        dict[key, default: []].insert(value)
        return true
    }

    private func removeFrom<Value: Hashable>(dict: inout [AnyDistributedReceptionKey: Set<Value>], key: AnyDistributedReceptionKey, value: Value) -> Set<Value>? {
        if dict[key]?.remove(value) != nil, dict[key]?.isEmpty ?? false {
            dict.removeValue(forKey: key)
        }

        return dict[key]
    }

    /// Remember that this guest did register itself under this key
    private func addGuestKeyMapping(identity: AnyActorIdentity, key: AnyDistributedReceptionKey) {
        self._identityToRegisteredKeys[identity, default: []].insert(key)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------

/// Represents a local subscription (for `receptionist.subscribe`) for a specific key
internal final class AnyDistributedReceptionListingSubscription: Hashable {
    let subscriptionID: ObjectIdentifier
    let key: AnyDistributedReceptionKey

    /// Offer a new listing to the subscription stream. // FIXME: implement this by offering single elements (!!!)
    private let onNext: @Sendable (AnyDistributedActor) -> Void
    var seenActorRegistrations: VersionVector

    init(subscriptionID: ObjectIdentifier,
         key: AnyDistributedReceptionKey,
         onNext: @escaping @Sendable (AnyDistributedActor) -> Void) {
        self.subscriptionID = subscriptionID
        self.key = key
        self.onNext = onNext
        self.seenActorRegistrations = .empty
    }

    /// Attempt to offer a registration to the subscriber of this stream.
    ///
    /// Since a subscription should never emit the same actor "appearing" multiple times,
    /// and each registration is unique per the origin node of the offered actor,
    /// we can check the incoming version, and if we're already "seen" it, we can
    /// safely ignore the offer.
    ///
    /// We implement this by storing a version vector that contains all nodes and versions we're
    /// getting potential offers from. Each incoming registration always has exactly one replicaID,
    /// because the changes are simply from "that node". We can merge the incoming version with out
    /// version vector, to see if it "advanced it" - if so, it must be a new registration and we have
    /// to emit the value. If it didn't advance the local "seen" version vector, it means we've already
    /// seen this actor in this specific stream, and don't need to emit it again.
    func tryOffer(registration: VersionedRegistration) {
        let oldSeenRegistrations = seenActorRegistrations
        seenActorRegistrations.merge(other: registration.version)

        switch seenActorRegistrations.compareTo(oldSeenRegistrations) {
        case .same:
            // the seen vector was unaffected by the merge, which means that the
            // incoming registration version was already seen, and thus we don't need to emit it again
            return
        case .happenedAfter:
            // the incoming registration has not yet been seen before,
            // which means that we should emit the actor to the stream.
            onNext(registration.actor)
        case  .concurrent:
            fatalError("""
                       It should not be possible for a version vector to be concurrent with a PAST version of itself before the merge
                          Previously: \(oldSeenRegistrations)
                          Current: \(seenActorRegistrations)
                       """)
        case .happenedBefore:
            fatalError("""
                       It should not be possible for a *merged* version vector to be in the PAST as compared with itself before the merge
                          Previously: \(oldSeenRegistrations)
                          Current: \(seenActorRegistrations)
                       """)
        }

    }

    static func == (lhs: AnyDistributedReceptionListingSubscription, rhs: AnyDistributedReceptionListingSubscription) -> Bool {
        lhs.subscriptionID == rhs.subscriptionID && lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.subscriptionID)
        hasher.combine(self.key)
    }
}
