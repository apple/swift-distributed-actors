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
//        : Actor
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

//    /// Subscribe to changes in checked-in actors under given `key`.
//    ///
//    /// The `subscriber` actor will be notified with `Reception.Listing<M>` messages when new actors register,
//    /// leave or die, under the passed in key.
//    func subscribe<Guest>(
//            _ myself: DistributedActor,
//            to key: DistributedReception.Key<Guest>
//    ) async -> Set<Guest>
//            where Guest: DistributedActor & __DistributedClusterActor

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
//        public typealias Element = Set<Guest>
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
                let id = ObjectIdentifier(self)
                // self.underlying = // receptionist.whenLocal { __secretlyKnownToBeLocal in // FIXME: can't do this since async?
                self.underlying = AsyncStream<Element> { continuation in
                    Task { // FIXME(distributed): get rid of this task
                        pprint("SUB continuation to key: \(key)")
                        await __secretlyKnownToBeLocal._subscribe(continuation: continuation, subscriptionID: id, to: key)
                        pprint("SUB DONE continuation to key: \(key)")
                    }
                    continuation.onTermination = { @Sendable(_) -> Void in
                        pprint("TERMINATED sub to key: \(key)")
                        Task {
                            await __secretlyKnownToBeLocal._cancelSubscription(subscriptionID: id, to: key)
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

internal final class DistributedReceptionistStorage {
    internal var _registrations: [AnyDistributedReceptionKey: Set<AnyDistributedActor>] = [:]
    internal var _subscriptions: [AnyDistributedReceptionKey: Set<AnyDistributedSubscribe>] = [:]

    /// Per (receptionist) node mapping of which keys are presently known to this receptionist on the given node.
    /// This is used to perform quicker cleanups upon a node/receptionist crashing, and thus all existing references
    /// on that node should be removed from our storage.
    private var _registeredKeysByNode: [UniqueNode: Set<AnyDistributedReceptionKey>] = [:]

    /// Allows for reverse lookups, when an actor terminates, we know from which registrations and subscriptions to remove it from.
    internal var _identityToKeys: [AnyActorIdentity: Set<AnyDistributedReceptionKey>] = [:]

    // ==== --------------------------------------------------------------------------------------------------------
    // MARK: Registrations

    /// - returns: `true` if the value was a newly inserted value, `false` otherwise
    func addRegistration<Guest>(key: AnyDistributedReceptionKey, guest: Guest) -> Bool
            where Guest: DistributedActor & __DistributedClusterActor {
        guard let address = guest.id._unwrapActorAddress else {
            return false
        }
        self.addGuestKeyMapping(identity: guest.id, key: key)
        self.storeRegistrationNodeRelation(key: key, node: address.uniqueNode)
        return self.addTo(dict: &self._registrations, key: key, value: guest.asAnyDistributedActor)
    }

    func removeRegistration<Guest>(key: AnyDistributedReceptionKey, guest: Guest) -> Set<AnyDistributedActor>?
            where Guest: DistributedActor & __DistributedClusterActor {
        let address = guest.id._forceUnwrapActorAddress

        _ = self.removeFromKeyMappings(guest.asAnyDistributedActor)
        self.removeSingleRegistrationNodeRelation(key: key, node: address.uniqueNode)
        return self.removeFrom(dict: &self._registrations, key: key, value: guest.asAnyDistributedActor)
    }

    func registrations(forKey key: AnyDistributedReceptionKey) -> Set<AnyDistributedActor>? {
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

    func addSubscription(key: AnyDistributedReceptionKey, subscription: AnyDistributedSubscribe) -> Bool {
        pprint("Add key: \(key), sub: \(subscription)")
        if let id = subscription.subscriber?.id {
            self.addGuestKeyMapping(identity: id, key: key)
        }
        return self.addTo(dict: &self._subscriptions, key: key, value: subscription)
    }

    @discardableResult
    func removeSubscription(key: AnyDistributedReceptionKey, subscription: AnyDistributedSubscribe) -> Set<AnyDistributedSubscribe>? {
        pprint("Remove key: \(key), sub: \(subscription)")
        if let id = subscription.subscriber?.id {
            _ = self.removeFromKeyMappings(identity: id)
        }
        return self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
    }

    func subscriptions(forKey key: AnyDistributedReceptionKey) -> Set<AnyDistributedSubscribe>? {
        self._subscriptions[key]
    }

    // FIXME: improve this to always pass around AddressableActorRef rather than just address (in receptionist Subscribe message), remove this trick then
    /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
    func removeFromKeyMappings(identity: AnyActorIdentity) -> RefMappingRemovalResult {
        fatalErrorBacktrace(#function)
//        let equalityHackRef = ActorRef<Never>(.deadLetters(.init(Logger(label: ""), address: address, system: nil)))
//        return self.removeFromKeyMappings(equalityHackRef.asAddressable)
    }

    /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
    func removeFromKeyMappings(_ ref: AnyDistributedActor) -> RefMappingRemovalResult {
        // let address = ref.id._forceUnwrapActorAddress

        guard let associatedKeys = self._identityToKeys.removeValue(forKey: ref.id) else {
            return RefMappingRemovalResult(registeredUnderKeys: [])
        }

        var registeredKeys: Set<AnyDistributedReceptionKey> = [] // TODO: OR we store it directly as registeredUnderKeys/subscribedToKeys in the dict
        for key in associatedKeys {
            if self._registrations[key]?.remove(ref) != nil {
                _ = registeredKeys.insert(key)
            }
            pinfo("WOULD WANT TO REMOVE: self._subscriptions[key]?.remove(AnyDistributedSubscribe(forRemovalOf: ref))")
            // self._subscriptions[key]?.remove(AnyDistributedSubscribe(forRemovalOf: ref)) // TODO: what about this?
        }

        return RefMappingRemovalResult(registeredUnderKeys: registeredKeys)
    }

    struct RefMappingRemovalResult {
        /// The (now removed) ref was registered under the following keys
        let registeredUnderKeys: Set<AnyDistributedReceptionKey>
        /// The following actors have been subscribed to this key
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
                registration.id._forceUnwrapActorAddress.uniqueNode != node
            }
            if !remainingRegistrations.isEmpty {
                self._registrations[key] = remainingRegistrations
            }

            // 2) and remove any of our subscriptions
            let subs: Set<AnyDistributedSubscribe> = self._subscriptions.removeValue(forKey: key) ?? []
            let prunedSubs = subs.filter { sub in
                sub.subscriber?.id._forceUnwrapActorAddress.uniqueNode != node // FIXME: does this make sense anymore, if we don't require myself on subscribe?
            }
            if remainingRegistrations.count != registrations.count {
                // only if the set of registered actors for this key was actually affected by this prune
                // we want to mark it as changed and ensure we contact all of such keys subscribers about the change.
                // In other words: we want to avoid pushing not-changed Listings.
                prune.changed[key] = prunedSubs
            }
            if !prunedSubs.isEmpty {
                self._subscriptions[key] = prunedSubs
            }
        }

        return prune
    }

    struct PrunedNodeDirective {
        fileprivate var changed: [AnyDistributedReceptionKey: Set<AnyDistributedSubscribe>] = [:]

        var keys: Dictionary<AnyDistributedReceptionKey, Set<AnyDistributedSubscribe>>.Keys {
            self.changed.keys
        }

        func peersToNotify(_ key: AnyDistributedReceptionKey) -> Set<AnyDistributedSubscribe> {
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

    private func addGuestKeyMapping(identity: AnyActorIdentity, key: AnyDistributedReceptionKey) {
        self._identityToKeys[identity, default: []].insert(key)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Messages

// FIXME: we have TWO subscribe kinds -- local and remote!
internal struct AnyDistributedSubscribe: Hashable, Sendable {
    let subscriptionID: ObjectIdentifier
    let subscriber: AnyDistributedActor? // FIXME(distributed) remove this, this is now a stream and not messaging an actor
    let send: @Sendable (Set<AnyDistributedActor>) async throws -> Void

    @available(*, deprecated, message: "Remove this, we use IDs now!")
    init<Subscriber>(subscriber: Subscriber,
                     subscriptionID: ObjectIdentifier,
                     send: @escaping @Sendable (Set<AnyDistributedActor>) async throws -> Void)
            where Subscriber: DistributedActor {
        self.subscriptionID = subscriptionID
        self.subscriber = subscriber.asAnyDistributedActor
        self.send = send
    }

    init(subscriptionID: ObjectIdentifier,
         send: @escaping @Sendable (Set<AnyDistributedActor>) async throws -> Void) {
        self.subscriptionID = subscriptionID
        self.subscriber = nil
        self.send = send
    }

    // This init we only use when we want to remove the value from sets etc.
//    @available(*, deprecated, message: "Remove this, we use IDs now!")
//    init(forRemovalOf subscriber: AnyDistributedActor) {
//        self.subscriber = subscriber
//        self.send = { _ in () }
//    }

    static func == (lhs: AnyDistributedSubscribe, rhs: AnyDistributedSubscribe) -> Bool {
        if lhs.subscriptionID == rhs.subscriptionID {
            return true
        }

        if lhs.subscriber != nil && rhs.subscriber != nil &&
               lhs.subscriber == rhs.subscriber {
            return true
        }

        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.subscriptionID)
        hasher.combine(self.subscriber)
    }
}
