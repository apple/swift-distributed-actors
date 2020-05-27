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

/// A receptionist is a system actor that allows users to register actors under
/// a key to make them available to other parts of the system, without having to
/// share a reference with that specific part directly. There are different reasons
/// for using the receptionist over direct sharing of references, e.g. parts of
/// the system can be brought up independently and then lookup the reference of
/// another part once it's ready, or subscribe to be notified once the other
/// part has registered. Actors usually register themselves with the receptionist
/// as part of their setup process.
///
/// The receptionist can be accessed through `system.receptionist`.
public enum Receptionist {
    public typealias Message = ReceptionistMessage

    // Implementation notes: // TODO: Intercept messages to register at remote receptionist, and handle locally?
    // Receptionist messages are a bit special. Technically we CAN allow sending them over to remotes
    // but we do not today. Generally though, for example registering with a remote's receptionist is a "bad idea"™
    // it is more efficient to register on the local one, so what we could do, is when sending to a remote receptionist,
    // is to detect that and rather send to the local one.

    internal static let naming: ActorNaming = .unique("receptionist")

    /// Used to register and lookup actors in the receptionist. The key is a combination
    /// of the string id and the message type of the actor.
    ///
    /// - See `Reception.Key` for the high-level `Actorable`/`Actor` compatible key API
    public class RegistrationKey<Message: Codable>: _RegistrationKey, CustomStringConvertible, ExpressibleByStringLiteral {
        public init(messageType: Message.Type, id: String) {
            super.init(id: id, typeHint: _typeName(messageType as Any.Type))
        }

        public init(_ value: String) {
            super.init(id: value, typeHint: _typeName(Message.self as Any.Type))
        }

        public required init(stringLiteral value: StringLiteralType) {
            super.init(id: value, typeHint: _typeName(Message.self as Any.Type))
        }

        internal func _unsafeAsActorRef(_ addressable: AddressableActorRef) -> ActorRef<Message> {
            if addressable.isRemote() {
                let remoteWellTypedPersonality: RemoteClusterActorPersonality<Message> = addressable.ref._unsafeGetRemotePersonality(Message.self)
                return ActorRef(.remote(remoteWellTypedPersonality))
            } else {
                guard let ref = addressable.ref as? ActorRef<Message> else {
                    fatalError("Type mismatch, expected: [\(String(reflecting: ActorRef<Message>.self))] got [\(addressable)]")
                }

                return ref
            }
        }

        internal override func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
            let ref: ActorRef<Message> = system._resolve(context: ResolveContext(address: address, system: system))
            return ref.asAddressable()
        }

        internal override var asAnyRegistrationKey: AnyRegistrationKey {
            AnyRegistrationKey(from: self)
        }

        public var description: String {
            "RegistrationKey(id: \(self.id), typeHint: \(self.typeHint))"
        }
    }

    /// When sent to receptionist will register the specified `ActorRef` under the given `RegistrationKey`
    public class Register<Message: Codable>: _Register {
        public let ref: ActorRef<Message>
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Registered<Message>>?

        public init(_ ref: ActorRef<Message>, key: RegistrationKey<Message>, replyTo: ActorRef<Registered<Message>>? = nil) {
            self.ref = ref
            self.key = key
            self.replyTo = replyTo
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "")
        }

        internal override var _addressableActorRef: AddressableActorRef {
            AddressableActorRef(self.ref)
        }

        internal override var _key: _RegistrationKey {
            self.key
        }

        internal override func replyRegistered() {
            self.replyTo?.tell(Registered(ref: self.ref, key: self.key))
        }

        public override var description: String {
            "Register(ref: \(self.ref), key: \(self.key), replyTo: \(String(reflecting: self.replyTo))"
        }
    }

    /// Response to a `Register` message
    public class Registered<Message: Codable>: NonTransportableActorMessage, CustomStringConvertible {
        public let ref: ActorRef<Message>
        public let key: RegistrationKey<Message>

        public init(ref: ActorRef<Message>, key: RegistrationKey<Message>) {
            self.ref = ref
            self.key = key
        }

        public var description: String {
            "Receptionist.Registered(ref: \(self.ref), key: \(self.key))"
        }
    }

    /// Used to lookup `ActorRef`s for the given `RegistrationKey`
    public class Lookup<Message: Codable>: _Lookup, ListingRequest, CustomStringConvertible {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, replyTo: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = replyTo
            super.init(_key: key)
        }

        required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        override func replyWith(_ refs: Set<AddressableActorRef>) {
            let typedRefs = refs.map { ref in
                key._unsafeAsActorRef(ref)
            }

            self.replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
        }

        public var description: String {
            "Receptionist.Lookup(key: \(self.key), replyTo: \(self.replyTo))"
        }
    }

    /// Subscribe to periodic updates of the specified key
    public class Subscribe<Message: Codable>: _Subscribe, ListingRequest, CustomStringConvertible {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, subscriber: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = subscriber
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        internal override var _key: _RegistrationKey {
            self.key.asAnyRegistrationKey
        }

        internal override var _boxed: AnySubscribe {
            AnySubscribe(subscribe: self)
        }

        internal override var _addressableActorRef: AddressableActorRef {
            self.replyTo.asAddressable()
        }

        func replyWith(_ refs: Set<AddressableActorRef>) {
            let typedRefs = refs.map { ref in
                key._unsafeAsActorRef(ref)
            }

            self.replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
        }

        public var description: String {
            "Receptionist.Subscribe(key: \(self.key), replyTo: \(self.replyTo))"
        }
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyRegistrationKey: Set<AddressableActorRef>] = [:]
        private var _subscriptions: [AnyRegistrationKey: Set<AnySubscribe>] = [:]

        /// Per (receptionist) node mapping of which keys are presently known to this receptionist on the given node.
        /// This is used to perform quicker cleanups upon a node/receptionist crashing, and thus all existing references
        /// on that node should be removed from our storage.
        private var _registeredKeysByNode: [UniqueNode: Set<AnyRegistrationKey>] = [:]

        /// Allows for reverse lookups, when an actor terminates, we know from which registrations and subscriptions to remove it from.
        internal var _addressToKeys: [ActorAddress: Set<AnyRegistrationKey>] = [:]

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Registrations

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        func addRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Bool {
            self.addRefKeyMapping(address: ref.address, key: key)
            self.storeRegistrationNodeRelation(key: key, node: ref.address.node)
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Set<AddressableActorRef>? {
            _ = self.removeFromKeyMappings(ref)
            self.removeSingleRegistrationNodeRelation(key: key, node: ref.address.node)
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyRegistrationKey) -> Set<AddressableActorRef>? {
            self._registrations[key]
        }

        private func storeRegistrationNodeRelation(key: AnyRegistrationKey, node: UniqueNode?) {
            if let node = node {
                self._registeredKeysByNode[node, default: []].insert(key)
            }
        }

        private func removeSingleRegistrationNodeRelation(key: AnyRegistrationKey, node: UniqueNode?) {
            // FIXME: Implement me (!), we need to make the storage a counter
            // and decrement here by one; once the counter reaches zero we know there is no more relationship
            // and we can prune this key/node relationship
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Subscriptions

        func addSubscription(key: AnyRegistrationKey, subscription: AnySubscribe) -> Bool {
            self.addRefKeyMapping(address: subscription.address, key: key)
            return self.addTo(dict: &self._subscriptions, key: key, value: subscription)
        }

        @discardableResult
        func removeSubscription(key: AnyRegistrationKey, subscription: AnySubscribe) -> Set<AnySubscribe>? {
            _ = self.removeFromKeyMappings(address: subscription.address)
            return self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
        }

        func subscriptions(forKey key: AnyRegistrationKey) -> Set<AnySubscribe>? {
            self._subscriptions[key]
        }

        // FIXME: improve this to always pass around AddressableActorRef rather than just address (in receptionist Subscribe message), remove this trick then
        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(address: ActorAddress) -> Set<AnyRegistrationKey> {
            let equalityHackRef = ActorRef<Never>(.deadLetters(.init(Logger(label: ""), address: address, system: nil)))
            return self.removeFromKeyMappings(equalityHackRef.asAddressable())
        }

        /// - Returns: set of keys that this actor was REGISTERED under, and thus listings associated with it should be updated
        func removeFromKeyMappings(_ ref: AddressableActorRef) -> Set<AnyRegistrationKey> {
            guard let associatedKeys = self._addressToKeys.removeValue(forKey: ref.address) else {
                return []
            }

            var registeredKeys: Set<AnyRegistrationKey> = [] // TODO: OR we store it directly as registeredUnderKeys/subscribedToKeys in the dict
            for key in associatedKeys {
                if self._registrations[key]?.remove(ref) != nil {
                    _ = registeredKeys.insert(key)
                }
                self._subscriptions[key]?.remove(.init(address: ref.address))
            }

            return registeredKeys
        }

        func pruneNode(_ node: UniqueNode) {
            guard let keys = self._registeredKeysByNode[node] else {
                // no keys were related to this node, we should have nothing to clean-up here
                return
            }

            // for every key that was related to the now terminated node
            for key in keys {
                // 1) we remove any registrations that it hosted
                let regs: Set<AddressableActorRef> = self._registrations.removeValue(forKey: key) ?? []
                let prunedRegs = regs.filter { $0.address.node != node }
                if !prunedRegs.isEmpty {
                    self._registrations[key] = prunedRegs
                }

                // 2) and remove any of our subscriptions
                let subs: Set<AnySubscribe> = self._subscriptions.removeValue(forKey: key) ?? []
                let prunedSubs = subs.filter { $0.address.node == node }
                if !prunedSubs.isEmpty {
                    self._subscriptions[key] = prunedSubs
                }
            }
        }

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        private func addTo<Value: Hashable>(dict: inout [AnyRegistrationKey: Set<Value>], key: AnyRegistrationKey, value: Value) -> Bool {
            guard !(dict[key]?.contains(value) ?? false) else {
                return false
            }

            dict[key, default: []].insert(value)
            return true
        }

        private func removeFrom<Value: Hashable>(dict: inout [AnyRegistrationKey: Set<Value>], key: AnyRegistrationKey, value: Value) -> Set<Value>? {
            if dict[key]?.remove(value) != nil, dict[key]?.isEmpty ?? false {
                dict.removeValue(forKey: key)
            }

            return dict[key]
        }

        private func addRefKeyMapping(address: ActorAddress, key: AnyRegistrationKey) {
            self._addressToKeys[address, default: []].insert(key)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist ActorRef Extensions

public extension ActorRef where Message == ReceptionistMessage {
    /// Register given actor ref under the reception key, for discovery by other actors (be it local or on other nodes, when clustered).
    func register<M>(_ ref: ActorRef<M>, key keyId: String, replyTo: ActorRef<Receptionist.Registered<M>>? = nil) {
        let key = Receptionist.RegistrationKey(messageType: M.self, id: keyId)
        self.register(ref, key: key, replyTo: replyTo)
    }

    /// Register given actor ref under the reception key, for discovery by other actors (be it local or on other nodes, when clustered).
    func register<M>(_ ref: ActorRef<M>, key: Receptionist.RegistrationKey<M>, replyTo: ActorRef<Receptionist.Registered<M>>? = nil) {
        self.tell(Receptionist.Register(ref, key: key, replyTo: replyTo))
    }

    /// Looks up actors by given `key`, replying (once) to the `replyTo` actor once the lookup has completed.
    ///
    /// - SeeAlso: `subscribe(key:subscriber:)`
    func lookup<M>(key: Receptionist.RegistrationKey<M>, replyTo: ActorRef<Receptionist.Listing<M>>) {
        self.tell(Receptionist.Lookup(key: key, replyTo: replyTo))
    }

    /// Looks up actors by given `key`.
    ///
    /// The closure is invoked _on the actor context_, meaning that it is safe to access and/or modify actor state from it.
    func lookup<M>(key: Receptionist.RegistrationKey<M>, timeout: TimeAmount = .effectivelyInfinite) -> AskResponse<Receptionist.Listing<M>> {
        self.ask(for: Receptionist.Listing<M>.self, timeout: timeout) {
            Receptionist.Lookup<M>(key: key, replyTo: $0)
        }
    }

    /// Subscribe to changes in checked-in actors under given `key`.
    /// The `subscriber` actor will be notified with `Receptionist.Listing<M>` messages when new actors register, leave or die,
    /// under the passed in key.
    func subscribe<M>(key: Receptionist.RegistrationKey<M>, subscriber: ActorRef<Receptionist.Listing<M>>) {
        self.tell(Receptionist.Subscribe(key: key, subscriber: subscriber))
    }
}

extension ActorPath {
    internal static let _receptionist: ActorPath = try! ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist")])
}

extension ActorAddress {
    internal static func _receptionist(on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._receptionist, incarnation: .wellKnown)
    }
}

/// Marker protocol for all receptionist messages
///
/// The message implementations are located in `Receptionist.*`
///
/// - SeeAlso:
///     - `Receptionist.Message`
///     - `Receptionist.Lookup`
///     - `Receptionist.Register`
///     - `Receptionist.Subscribe`
public class ReceptionistMessage: Codable {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

// TODO: Receptionist._Register
public class _Register: ReceptionistMessage, NonTransportableActorMessage, CustomStringConvertible {
    var _addressableActorRef: AddressableActorRef { undefined() }
    var _key: _RegistrationKey { undefined() }

    func replyRegistered() {
        undefined()
    }

    public var description: String {
        "Receptionist._Register(_addressableActorRef: \(self._addressableActorRef), _key: \(self._key))"
    }
}

// TODO: Receptionist._Lookup
// TODO: or rather move to not classes here: https://github.com/apple/swift-distributed-actors/issues/510
public class _Lookup: ReceptionistMessage, NonTransportableActorMessage {
    let _key: _RegistrationKey

    init(_key: _RegistrationKey) {
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

// TODO: Receptionist._Registration key, or rather move to not classes here: https://github.com/apple/swift-distributed-actors/issues/510
public class _RegistrationKey {
    let id: String
    let typeHint: FullyQualifiedTypeName

    init(id: String, typeHint: FullyQualifiedTypeName) {
        self.id = id
        self.typeHint = typeHint
    }

    var asAnyRegistrationKey: AnyRegistrationKey {
        undefined()
    }

    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `RegistrationKey`
    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
        undefined()
    }
}

internal enum ReceptionistError: Error {
    case typeMismatch(expected: String)
}

internal class AnyRegistrationKey: _RegistrationKey, Codable, Hashable {
    enum CodingKeys: CodingKey {
        case id
        case typeHint
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let id = try container.decode(String.self, forKey: .id)
        let typeHint = try container.decode(String.self, forKey: .typeHint)
        super.init(id: id, typeHint: typeHint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.id, forKey: .id)
        try container.encode(self.typeHint, forKey: .typeHint)
    }

    init(from key: _RegistrationKey) {
        super.init(id: key.id, typeHint: key.typeHint)
    }

    override func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        system.personalDeadLetters(type: Never.self, recipient: address).asAddressable()
    }

    override var asAnyRegistrationKey: AnyRegistrationKey {
        self
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(typeHint)
    }

    static func == (lhs: AnyRegistrationKey, rhs: AnyRegistrationKey) -> Bool {
        if lhs === rhs {
            return true
        }
        if type(of: lhs) != type(of: rhs) {
            return false
        }
        if lhs.id != rhs.id {
            return false
        }
        if lhs.typeHint != rhs.typeHint {
            return false
        }
        return true
    }
}

public class _Subscribe: ReceptionistMessage, NonTransportableActorMessage {
    var _key: _RegistrationKey {
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

    init<M>(subscribe: Receptionist.Subscribe<M>) {
        self.address = subscribe.replyTo.address
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
    associatedtype Message: Codable

    var key: Receptionist.RegistrationKey<Message> { get }
    var _key: _RegistrationKey { get }

    var replyTo: ActorRef<Receptionist.Listing<Message>> { get }

    func replyWith(_ refs: Set<AddressableActorRef>)
}
