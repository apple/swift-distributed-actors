//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
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
///
/// - SeeAlso: `SystemReceptionist`
public struct Receptionist {
    public typealias Message = ReceptionistMessage

    // Implementation notes: // TODO: Intercept messages to register at remote receptionist, and handle locally?
    // Receptionist messages are a bit special. Technically we CAN allow sending them over to remotes
    // but we do not today. Generally though, for example registering with a remote's receptionist is a "bad idea"™
    // it is more efficient to register on the local one, so what we could do, is when sending to a remote receptionist,
    // is to detect that and rather send to the local one.

    internal static let naming: ActorNaming = .unique("receptionist")

    /// :nodoc: INTERNAL API
    /// When sent to receptionist will register the specified `ActorRef` under the given `Reception.Key`
    public class Register<Guest: ReceptionistGuest>: AnyRegister {
        public let guest: Guest
        public let key: Reception.Key<Guest>
        public let replyTo: ActorRef<Reception.Registered<Guest>>?

        public init(_ ref: Guest, key: Reception.Key<Guest>, replyTo: ActorRef<Reception.Registered<Guest>>? = nil) {
            self.guest = ref
            self.key = key
            self.replyTo = replyTo
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "")
        }

        internal override var _addressableActorRef: AddressableActorRef {
            AddressableActorRef(self.guest._ref)
        }

        internal override var _key: AnyReceptionKey {
            self.key.asAnyKey
        }

        internal override func replyRegistered() {
            self.replyTo?.tell(Reception.Registered(self.guest, key: self.key))
        }

        public override var description: String {
            "Register(ref: \(self.guest), key: \(self.key), replyTo: \(String(reflecting: self.replyTo))"
        }
    }

    /// :nodoc: INTERNAL API
    /// Used to lookup `ActorRef`s for the given `Reception.Key`
    public class Lookup<Guest: ReceptionistGuest>: _Lookup, ListingRequest, CustomStringConvertible {
        public let key: Reception.Key<Guest>
        public let subscriber: ActorRef<Reception.Listing<Guest>>

        public init(key: Reception.Key<Guest>, replyTo: ActorRef<Reception.Listing<Guest>>) {
            self.key = key
            self.subscriber = replyTo
            super.init(_key: key.asAnyKey)
        }

        required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        override func replyWith(_ refs: Set<AddressableActorRef>) {
            self.subscriber.tell(Reception.Listing(refs: refs, key: self.key))
        }

        public var description: String {
            "Receptionist.Lookup(key: \(self.key), replyTo: \(self.subscriber))"
        }
    }

    /// :nodoc: INTERNAL API
    /// Subscribe to periodic updates of the specified key
    public class Subscribe<Guest: ReceptionistGuest>: _Subscribe, ListingRequest, CustomStringConvertible {
        public let key: Reception.Key<Guest>
        public let subscriber: ActorRef<Reception.Listing<Guest>>

        public init(key: Reception.Key<Guest>, subscriber: ActorRef<Reception.Listing<Guest>>) {
            self.key = key
            self.subscriber = subscriber
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        internal override var _key: AnyReceptionKey {
            self.key.asAnyKey
        }

        internal override var _boxed: AnySubscribe {
            AnySubscribe(subscribe: self)
        }

        internal override var _addressableActorRef: AddressableActorRef {
            self.subscriber.asAddressable
        }

        func replyWith(_ refs: Set<AddressableActorRef>) {
            self.subscriber.tell(Reception.Listing(refs: refs, key: self.key))
        }

        public var description: String {
            "Receptionist.Subscribe(key: \(self.key), replyTo: \(self.subscriber))"
        }
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyReceptionKey: Set<AddressableActorRef>] = [:]
        internal var _subscriptions: [AnyReceptionKey: Set<AnySubscribe>] = [:]

        /// Per (receptionist) node mapping of which keys are presently known to this receptionist on the given node.
        /// This is used to perform quicker cleanups upon a node/receptionist crashing, and thus all existing references
        /// on that node should be removed from our storage.
        private var _registeredKeysByNode: [UniqueNode: Set<AnyReceptionKey>] = [:]

        /// Allows for reverse lookups, when an actor terminates, we know from which registrations and subscriptions to remove it from.
        internal var _addressToKeys: [ActorAddress: Set<AnyReceptionKey>] = [:]

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Registrations

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        func addRegistration(key: AnyReceptionKey, ref: AddressableActorRef) -> Bool {
            self.addRefKeyMapping(address: ref.address, key: key)
            self.storeRegistrationNodeRelation(key: key, node: ref.address.uniqueNode)
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyReceptionKey, ref: AddressableActorRef) -> Set<AddressableActorRef>? {
            _ = self.removeFromKeyMappings(ref)
            self.removeSingleRegistrationNodeRelation(key: key, node: ref.address.uniqueNode)
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyReceptionKey) -> Set<AddressableActorRef>? {
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
            self.addRefKeyMapping(address: subscription.address, key: key)
            return self.addTo(dict: &self._subscriptions, key: key, value: subscription)
        }

        @discardableResult
        func removeSubscription(key: AnyReceptionKey, subscription: AnySubscribe) -> Set<AnySubscribe>? {
            _ = self.removeFromKeyMappings(address: subscription.address)
            return self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
        }

        func subscriptions(forKey key: AnyReceptionKey) -> Set<AnySubscribe>? {
            self._subscriptions[key]
        }

        // FIXME: improve this to always pass around AddressableActorRef rather than just address (in receptionist Subscribe message), remove this trick then
        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(address: ActorAddress) -> RefMappingRemovalResult {
            let equalityHackRef = ActorRef<Never>(.deadLetters(.init(Logger(label: ""), address: address, system: nil)))
            return self.removeFromKeyMappings(equalityHackRef.asAddressable)
        }

        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(_ ref: AddressableActorRef) -> RefMappingRemovalResult {
            guard let associatedKeys = self._addressToKeys.removeValue(forKey: ref.address) else {
                return RefMappingRemovalResult(registeredUnderKeys: [])
            }

            var registeredKeys: Set<AnyReceptionKey> = [] // TODO: OR we store it directly as registeredUnderKeys/subscribedToKeys in the dict
            for key in associatedKeys {
                if self._registrations[key]?.remove(ref) != nil {
                    _ = registeredKeys.insert(key)
                }
                self._subscriptions[key]?.remove(.init(address: ref.address))
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
                let registrations: Set<AddressableActorRef> = self._registrations.removeValue(forKey: key) ?? []
                let remainingRegistrations = registrations.filter { $0.address.uniqueNode != node }
                if !remainingRegistrations.isEmpty {
                    self._registrations[key] = remainingRegistrations
                }

                // 2) and remove any of our subscriptions
                let subs: Set<AnySubscribe> = self._subscriptions.removeValue(forKey: key) ?? []
                let prunedSubs = subs.filter { $0.address.uniqueNode != node }
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

        private func addRefKeyMapping(address: ActorAddress, key: AnyReceptionKey) {
            self._addressToKeys[address, default: []].insert(key)
        }
    }
}

extension ActorPath {
    internal static let receptionist: ActorPath = try! ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist")])
}

extension ActorAddress {
    internal static func _receptionist(on node: UniqueNode) -> ActorAddress {
        ActorPath.receptionist.makeRemoteAddress(on: node, incarnation: .wellKnown)
    }
}

/// Represents an entity that is able to register with the `Receptionist`.
///
/// It is either an `ActorRef<Message>` or an `Actor<Act>`.
public protocol ReceptionistGuest {
    associatedtype Message: Codable

    // TODO: can we hide this? Relates to: https://bugs.swift.org/browse/SR-5880
    var _ref: ActorRef<Message> { get }
}

extension ActorRef: ReceptionistGuest {
    public var _ref: ActorRef<Message> { self }
}

// extension ActorProtocol: ReceptionistGuest {
//    public var _ref: ActorRef<Message> { self.ref }
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
/// :nodoc: INTERNAL API
public class ReceptionistMessage: Codable, @unchecked Sendable {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

// TODO: Receptionist._Register
/// :nodoc: INTERNAL API
public class AnyRegister: ReceptionistMessage, NonTransportableActorMessage, CustomStringConvertible {
    var _addressableActorRef: AddressableActorRef { undefined() }
    var _key: AnyReceptionKey { undefined() }

    func replyRegistered() {
        undefined()
    }

    public var description: String {
        "Receptionist._Register(_addressableActorRef: \(self._addressableActorRef), _key: \(self._key))"
    }
}

public class _Lookup: ReceptionistMessage, NonTransportableActorMessage {
    let _key: AnyReceptionKey

    init(_key: AnyReceptionKey) {
        self._key = _key
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
    }

    func replyWith(_ refs: Set<AddressableActorRef>) {
        undefined()
    }

    func replyWith(_ refs: [AddressableActorRef]) {
        undefined()
    }
}

/// :nodoc: INTERNAL API
protocol ReceptionKeyProtocol {
    var id: String { get }
    var guestType: Any.Type { get }

    var asAnyKey: AnyReceptionKey { get }

    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `Reception.Key`
    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef
}

// :nodoc:
public struct AnyReceptionKey: ReceptionKeyProtocol, Sendable, Codable, Hashable, CustomStringConvertible {
    enum CodingKeys: CodingKey {
        case id
        case guestTypeManifest
    }

    let id: String
    let guestType: Any.Type

    init<Guest>(_ key: Reception.Key<Guest>) {
        self.id = key.id
        self.guestType = Guest.self
    }

    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        system.personalDeadLetters(type: Never.self, recipient: address).asAddressable
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

public class _Subscribe: ReceptionistMessage, NonTransportableActorMessage {
    var _key: AnyReceptionKey {
        fatalErrorBacktrace("failed \(#function)")
    }

    var _boxed: AnySubscribe {
        fatalErrorBacktrace("failed \(#function)")
    }

    var _addressableActorRef: AddressableActorRef {
        fatalErrorBacktrace("failed \(#function)")
    }

    public override init() {
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
    }
}

internal struct AnySubscribe: Hashable {
    let address: ActorAddress
    let _replyWith: (Set<AddressableActorRef>) -> Void

    init<Guest>(subscribe: Receptionist.Subscribe<Guest>) where Guest: ReceptionistGuest {
        self.address = subscribe.subscriber.address
        self._replyWith = subscribe.replyWith
    }

    init(address: ActorAddress) {
        self.address = address
        self._replyWith = { _ in () }
    }

    func replyWith(_ refs: Set<AddressableActorRef>) {
        self._replyWith(refs)
    }

    static func == (lhs: AnySubscribe, rhs: AnySubscribe) -> Bool {
        lhs.address == rhs.address
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.address)
    }
}

internal protocol ListingRequest {
    associatedtype Guest: ReceptionistGuest

    var key: Reception.Key<Guest> { get }
    var _key: AnyReceptionKey { get }

    var subscriber: ActorRef<Reception.Listing<Guest>> { get }

    func replyWith(_ refs: Set<AddressableActorRef>)
}

internal final class _ReceptionistDelayedListingFlushTick: ReceptionistMessage, NonTransportableActorMessage {
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
