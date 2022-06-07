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

import Logging

/// :nodoc:
///
/// A receptionist is a system actor that allows users to register actors under
/// a key to make them available to other parts of the system, without having to
/// share a reference with that specific part directly. There are different reasons
/// for using the receptionist over direct sharing of references, e.g. parts of
/// the system can be brought up independently and then lookup the reference of
/// another part once it's ready, or subscribe to be notified once the other
/// part has registered. Actors usually register themselves with the receptionist
/// as part of their setup process.
public struct Receptionist {
    public typealias Message = _ReceptionistMessage

    // Implementation notes: // TODO: Intercept messages to register at remote receptionist, and handle locally?
    // Receptionist messages are a bit special. Technically we CAN allow sending them over to remotes
    // but we do not today. Generally though, for example registering with a remote's receptionist is a "bad idea"™
    // it is more efficient to register on the local one, so what we could do, is when sending to a remote receptionist,
    // is to detect that and rather send to the local one.

    internal static let naming: _ActorNaming = .unique("receptionist-ref")

    /// INTERNAL API
    /// When sent to receptionist will register the specified `_ActorRef` under the given `_Reception.Key`
    public class Register<Guest: _ReceptionistGuest>: _AnyRegister {
        public let guest: Guest
        public let key: _Reception.Key<Guest>
        public let replyTo: _ActorRef<_Reception.Registered<Guest>>?

        public init(_ ref: Guest, key: _Reception.Key<Guest>, replyTo: _ActorRef<_Reception.Registered<Guest>>? = nil) {
            self.guest = ref
            self.key = key
            self.replyTo = replyTo
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "")
        }

        override internal var _addressableActorRef: _AddressableActorRef {
            _AddressableActorRef(self.guest._ref)
        }

        override internal var _key: AnyReceptionKey {
            self.key.asAnyKey
        }

        override internal func replyRegistered() {
            self.replyTo?.tell(_Reception.Registered(self.guest, key: self.key))
        }

        override public var description: String {
            "Register(ref: \(self.guest), key: \(self.key), replyTo: \(String(reflecting: self.replyTo))"
        }
    }

    /// INTERNAL API
    /// Used to lookup `_ActorRef`s for the given `_Reception.Key`
    public class Lookup<Guest: _ReceptionistGuest>: _Lookup, ListingRequest, CustomStringConvertible {
        public let key: _Reception.Key<Guest>
        public let subscriber: _ActorRef<_Reception.Listing<Guest>>

        public init(key: _Reception.Key<Guest>, replyTo: _ActorRef<_Reception.Listing<Guest>>) {
            self.key = key
            self.subscriber = replyTo
            super.init(_key: key.asAnyKey)
        }

        required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        override func replyWith(_ refs: Set<_AddressableActorRef>) {
            self.subscriber.tell(_Reception.Listing(refs: refs, key: self.key))
        }

        public var description: String {
            "Receptionist.Lookup(key: \(self.key), replyTo: \(self.subscriber))"
        }
    }

    /// INTERNAL API
    /// Subscribe to periodic updates of the specified key
    public class Subscribe<Guest: _ReceptionistGuest>: _Subscribe, ListingRequest, CustomStringConvertible {
        public let key: _Reception.Key<Guest>
        public let subscriber: _ActorRef<_Reception.Listing<Guest>>

        public init(key: _Reception.Key<Guest>, subscriber: _ActorRef<_Reception.Listing<Guest>>) {
            self.key = key
            self.subscriber = subscriber
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        override internal var _key: AnyReceptionKey {
            self.key.asAnyKey
        }

        override internal var _boxed: AnySubscribe {
            AnySubscribe(subscribe: self)
        }

        override internal var _addressableActorRef: _AddressableActorRef {
            self.subscriber.asAddressable
        }

        func replyWith(_ refs: Set<_AddressableActorRef>) {
            self.subscriber.tell(_Reception.Listing(refs: refs, key: self.key))
        }

        public var description: String {
            "Receptionist.Subscribe(key: \(self.key), replyTo: \(self.subscriber))"
        }
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyReceptionKey: Set<_AddressableActorRef>] = [:]
        internal var _subscriptions: [AnyReceptionKey: Set<AnySubscribe>] = [:]

        /// Per (receptionist) node mapping of which keys are presently known to this receptionist on the given node.
        /// This is used to perform quicker cleanups upon a node/receptionist crashing, and thus all existing references
        /// on that node should be removed from our storage.
        private var _registeredKeysByNode: [UniqueNode: Set<AnyReceptionKey>] = [:]

        /// Allows for reverse lookups, when an actor terminates, we know from which registrations and subscriptions to remove it from.
        internal var _idToKeys: [ActorID: Set<AnyReceptionKey>] = [:]

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Registrations

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        func addRegistration(key: AnyReceptionKey, ref: _AddressableActorRef) -> Bool {
            self.addRefKeyMapping(id: ref.id, key: key)
            self.storeRegistrationNodeRelation(key: key, node: ref.id.uniqueNode)
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyReceptionKey, ref: _AddressableActorRef) -> Set<_AddressableActorRef>? {
            _ = self.removeFromKeyMappings(ref)
            self.removeSingleRegistrationNodeRelation(key: key, node: ref.id.uniqueNode)
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyReceptionKey) -> Set<_AddressableActorRef>? {
            self._registrations[key]
        }

        private func storeRegistrationNodeRelation(key: AnyReceptionKey, node: UniqueNode?) {
            if let node = node {
                self._registeredKeysByNode[node, default: []].insert(key)
            }
        }

        private func removeSingleRegistrationNodeRelation(key: AnyReceptionKey, node: UniqueNode?) {
            // FIXME: Implement me (!), we need to make the storage a counter
            //        and decrement here by one; once the counter reaches zero we know there is no more relationship
            //        and we can prune this key/node relationship
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Subscriptions

        func addSubscription(key: AnyReceptionKey, subscription: AnySubscribe) -> Bool {
            self.addRefKeyMapping(id: subscription.id, key: key)
            return self.addTo(dict: &self._subscriptions, key: key, value: subscription)
        }

        @discardableResult
        func removeSubscription(key: AnyReceptionKey, subscription: AnySubscribe) -> Set<AnySubscribe>? {
            _ = self.removeFromKeyMappings(id: subscription.id)
            return self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
        }

        func subscriptions(forKey key: AnyReceptionKey) -> Set<AnySubscribe>? {
            self._subscriptions[key]
        }

        // FIXME: improve this to always pass around _AddressableActorRef rather than just address (in receptionist Subscribe message), remove this trick then
        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(id: ActorID) -> RefMappingRemovalResult {
            let equalityHackRef = _ActorRef<Never>(.deadLetters(.init(Logger(label: ""), id: id, system: nil)))
            return self.removeFromKeyMappings(equalityHackRef.asAddressable)
        }

        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(_ ref: _AddressableActorRef) -> RefMappingRemovalResult {
            guard let associatedKeys = self._idToKeys.removeValue(forKey: ref.id) else {
                return RefMappingRemovalResult(registeredUnderKeys: [])
            }

            var registeredKeys: Set<AnyReceptionKey> = [] // TODO: OR we store it directly as registeredUnderKeys/subscribedToKeys in the dict
            for key in associatedKeys {
                if self._registrations[key]?.remove(ref) != nil {
                    _ = registeredKeys.insert(key)
                }
                self._subscriptions[key]?.remove(.init(id: ref.id))
            }

            return RefMappingRemovalResult(
                registeredUnderKeys: registeredKeys
            )
        }

        struct RefMappingRemovalResult {
            /// The (now removed) ref was registered under the following keys
            let registeredUnderKeys: Set<AnyReceptionKey>
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
                let registrations: Set<_AddressableActorRef> = self._registrations.removeValue(forKey: key) ?? []
                let remainingRegistrations = registrations.filter { $0.id.uniqueNode != node }
                if !remainingRegistrations.isEmpty {
                    self._registrations[key] = remainingRegistrations
                }

                // 2) and remove any of our subscriptions
                let subs: Set<AnySubscribe> = self._subscriptions.removeValue(forKey: key) ?? []
                let prunedSubs = subs.filter { $0.id.uniqueNode != node }
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
            fileprivate var changed: [AnyReceptionKey: Set<AnySubscribe>] = [:]

            var keys: Dictionary<AnyReceptionKey, Set<AnySubscribe>>.Keys {
                self.changed.keys
            }

            func peersToNotify(_ key: AnyReceptionKey) -> Set<AnySubscribe> {
                self.changed[key] ?? []
            }
        }

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        private func addTo<Value: Hashable>(dict: inout [AnyReceptionKey: Set<Value>], key: AnyReceptionKey, value: Value) -> Bool {
            guard !(dict[key]?.contains(value) ?? false) else {
                return false
            }

            dict[key, default: []].insert(value)
            return true
        }

        private func removeFrom<Value: Hashable>(dict: inout [AnyReceptionKey: Set<Value>], key: AnyReceptionKey, value: Value) -> Set<Value>? {
            if dict[key]?.remove(value) != nil, dict[key]?.isEmpty ?? false {
                dict.removeValue(forKey: key)
            }

            return dict[key]
        }

        private func addRefKeyMapping(id: ActorID, key: AnyReceptionKey) {
            self._idToKeys[id, default: []].insert(key)
        }
    }
}

extension ActorPath {
    /// The _ActorRef<> receptionist, to be eventually removed.
    static let actorRefReceptionist: ActorPath =
        try! ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist-ref")])

    /// The 'distributed actor' receptionist's well-known path.
    static let distributedActorReceptionist: ActorPath =
        try! ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist")])
}

extension ActorID {
    enum ReceptionistType {
        case actorRefs
        case distributedActors
    }

    static func _receptionist(on node: UniqueNode, for type: ReceptionistType) -> ActorID {
        switch type {
        case .actorRefs:
            return ActorPath.actorRefReceptionist.makeRemoteID(on: node, incarnation: .wellKnown)
        case .distributedActors:
            return ActorPath.distributedActorReceptionist.makeRemoteID(on: node, incarnation: .wellKnown)
        }
    }
}

/// Represents an entity that is able to register with the `Receptionist`.
///
/// It is either an `_ActorRef<Message>`.
public protocol _ReceptionistGuest {
    associatedtype Message: Codable

    // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
    var _ref: _ActorRef<Message> { get }
}

extension _ActorRef: _ReceptionistGuest {
    public var _ref: _ActorRef<Message> { self }
}

// extension ActorProtocol: _ReceptionistGuest {
//    public var _ref: _ActorRef<Message> { self.ref }
// }

/// Marker protocol for all receptionist messages
///
/// The message implementations are located in `Receptionist.*`
///
/// - SeeAlso:
///     - `Receptionist.Message`
///     - `Receptionist.Lookup`
///     - `Receptionist.Register`
///     - `Receptionist.Subscribe`
/// INTERNAL API
public class _ReceptionistMessage: Codable, @unchecked Sendable {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

/// INTERNAL API
public class _AnyRegister: _ReceptionistMessage, NonTransportableActorMessage, CustomStringConvertible {
    var _addressableActorRef: _AddressableActorRef { _undefined() }
    var _key: AnyReceptionKey { _undefined() }

    func replyRegistered() {
        _undefined()
    }

    public var description: String {
        "Receptionist._Register(_addressableActorRef: \(self._addressableActorRef), _key: \(self._key))"
    }
}

public class _Lookup: _ReceptionistMessage, NonTransportableActorMessage {
    let _key: AnyReceptionKey

    init(_key: AnyReceptionKey) {
        self._key = _key
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
    }

    func replyWith(_ refs: Set<_AddressableActorRef>) {
        _undefined()
    }

    func replyWith(_ refs: [_AddressableActorRef]) {
        _undefined()
    }
}

/// INTERNAL API
protocol ReceptionKeyProtocol {
    var id: String { get }
    var guestType: Any.Type { get }

    var asAnyKey: AnyReceptionKey { get }

    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `_Reception.Key`
    func resolve(system: ClusterSystem, id: ActorID) -> _AddressableActorRef
}

// :nodoc:
public struct AnyReceptionKey: ReceptionKeyProtocol, Sendable, Codable, Hashable, CustomStringConvertible {
    enum CodingKeys: CodingKey {
        case id
        case guestTypeManifest
    }

    let id: String
    let guestType: Any.Type

    init<Guest>(_ key: _Reception.Key<Guest>) {
        self.id = key.id
        self.guestType = Guest.self
    }

    func resolve(system: ClusterSystem, id: ActorID) -> _AddressableActorRef {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        system.personalDeadLetters(type: Never.self, recipient: id).asAddressable
    }

    var asAnyKey: AnyReceptionKey {
        self
    }

    public var description: String {
        "AnyReceptionistKey<\(reflecting: self.guestType)>(\(self.id))"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(ObjectIdentifier(self.guestType))
    }

    public static func == (lhs: AnyReceptionKey, rhs: AnyReceptionKey) -> Bool {
        if type(of: lhs) != type(of: rhs) {
            return false
        }
        if lhs.id != rhs.id {
            return false
        }
        if ObjectIdentifier(lhs.guestType) != ObjectIdentifier(rhs.guestType) {
            return false
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)

        let guestTypeManifest = try container.decode(Serialization.Manifest.self, forKey: .guestTypeManifest)
        self.guestType = try context.summonType(from: guestTypeManifest)
    }

    public func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, Self.self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.id, forKey: .id)
        let guestTypeManifest = try context.serialization.outboundManifest(self.guestType)
        try container.encode(guestTypeManifest, forKey: .guestTypeManifest)
    }
}

public class _Subscribe: _ReceptionistMessage, NonTransportableActorMessage {
    var _key: AnyReceptionKey {
        fatalErrorBacktrace("failed \(#function)")
    }

    var _boxed: AnySubscribe {
        fatalErrorBacktrace("failed \(#function)")
    }

    var _addressableActorRef: _AddressableActorRef {
        fatalErrorBacktrace("failed \(#function)")
    }

    override public init() {
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
    }
}

internal struct AnySubscribe: Hashable {
    let id: ActorID
    let _replyWith: (Set<_AddressableActorRef>) -> Void

    init<Guest>(subscribe: Receptionist.Subscribe<Guest>) where Guest: _ReceptionistGuest {
        self.id = subscribe.subscriber.id
        self._replyWith = subscribe.replyWith
    }

    init(id: ActorID) {
        self.id = id
        self._replyWith = { _ in () }
    }

    func replyWith(_ refs: Set<_AddressableActorRef>) {
        self._replyWith(refs)
    }

    static func == (lhs: AnySubscribe, rhs: AnySubscribe) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

internal protocol ListingRequest {
    associatedtype Guest: _ReceptionistGuest

    var key: _Reception.Key<Guest> { get }
    var _key: AnyReceptionKey { get }

    var subscriber: _ActorRef<_Reception.Listing<Guest>> { get }

    func replyWith(_ refs: Set<_AddressableActorRef>)
}

internal final class _ReceptionistDelayedListingFlushTick: _ReceptionistMessage, NonTransportableActorMessage {
    let key: AnyReceptionKey

    init(key: AnyReceptionKey) {
        self.key = key
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist Errors

internal enum ReceptionistError: Error {
    case typeMismatch(expected: String)
}
