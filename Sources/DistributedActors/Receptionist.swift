//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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

    internal static let naming: ActorNaming = .unique("receptionist")

    /// Used to register and lookup actors in the receptionist. The key is a combination
    /// of the string id and the message type of the actor.
    public struct RegistrationKey<Message>: _RegistrationKey {
        public let id: String

        public init(_ type: Message.Type, id: String) {
            self.id = id
        }

        internal func _unsafeAsActorRef(_ addressable: AddressableActorRef) -> ActorRef<Message> {
            if addressable.isRemote() {
                let remotePersonality: RemotePersonality<Any> = addressable.ref._unsafeGetRemotePersonality()
                let remoteWellTypedPersonality: RemotePersonality<Message> = remotePersonality.cast(to: Message.self)
                return ActorRef(.remote(remoteWellTypedPersonality))
            } else {
                guard let ref = addressable.ref as? ActorRef<Message> else {
                    fatalError("Type mismatch, expected: [\(String(reflecting: ActorRef<Message>.self))] got [\(addressable)]")
                }

                return ref
            }
        }

        internal func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
            let ref: ActorRef<Message> = system._resolve(context: ResolveContext(address: address, system: system))
            return ref.asAddressable()
        }

        internal var typeString: FullyQualifiedTypeName {
            String(reflecting: Message.self)
        }

        internal var asAnyRegistrationKey: AnyRegistrationKey {
            AnyRegistrationKey(from: self)
        }
    }

    /// When sent to receptionist will register the specified `ActorRef` under the given `RegistrationKey`
    public struct Register<Message>: _Register {
        public let ref: ActorRef<Message>
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Registered<Message>>?

        public init(_ ref: ActorRef<Message>, key: RegistrationKey<Message>, replyTo: ActorRef<Registered<Message>>? = nil) {
            self.ref = ref
            self.key = key
            self.replyTo = replyTo
        }

        internal var _addressableActorRef: AddressableActorRef {
            return AddressableActorRef(self.ref)
        }

        internal var _key: _RegistrationKey {
            return self.key
        }

        internal func replyRegistered() {
            self.replyTo?.tell(Registered(ref: self.ref, key: self.key))
        }
    }

    /// Response to a `Register` message
    public struct Registered<Message> {
        public let ref: ActorRef<Message>
        public let key: RegistrationKey<Message>
    }

    /// Used to lookup `ActorRef`s for the given `RegistrationKey`
    public struct Lookup<Message>: ListingRequest, _Lookup {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, replyTo: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = replyTo
        }
    }

    /// Subscribe to periodic updates of the specified key
    public struct Subscribe<Message>: _Subscribe, ListingRequest {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, subscriber: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = subscriber
        }

        internal var _asAnySubscribe: AnySubscribe {
            AnySubscribe(subscribe: self)
        }

        var _asAddressableActorRef: AddressableActorRef {
            self.replyTo.asAddressable()
        }
    }

    /// Response to `Lookup` and `Subscribe` requests
    public struct Listing<Message>: Equatable, CustomStringConvertible {
        public let refs: Set<ActorRef<Message>>
        public var description: String {
            "Listing<\(Message.self)>(\(self.refs.map { $0.address }))"
        }
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyRegistrationKey: Set<AddressableActorRef>] = [:]
        private var _subscriptions: [AnyRegistrationKey: Set<AnySubscribe>] = [:]

        /// Allows for reverse lookups, when an actor terminates, we know from which registrations and subscriptions to remove it from.
        internal var _addressToKeys: [ActorAddress: Set<AnyRegistrationKey>] = [:]

        /// - returns: `true` if the value was a newly inserted value, `false` otherwise
        func addRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Bool {
            self.addRefKeyMapping(address: ref.address, key: key)
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Set<AddressableActorRef>? {
            _ = self.removeFromKeyMappings(ref)
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyRegistrationKey) -> Set<AddressableActorRef>? {
            self._registrations[key]
        }

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
        let key = Receptionist.RegistrationKey(M.self, id: keyId)
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

/// Receptionist for local execution. Does not depend on a cluster being available.
internal enum LocalReceptionist {
    static var behavior: Behavior<Receptionist.Message> {
        return .setup { context in
            let storage = Receptionist.Storage()

            // TODO: implement configurable logging (to log if it gets registers etc)
            // TODO: since all states access all the same state, allocating a local receptionist would result in less passing around storage
            return .receiveMessage { message in
                switch message {
                case let message as _Register:
                    try LocalReceptionist.onRegister(context: context, message: message, storage: storage)

                case let message as _Lookup:
                    try LocalReceptionist.onLookup(context: context, message: message, storage: storage)

                case let message as _Subscribe:
                    try LocalReceptionist.onSubscribe(context: context, message: message, storage: storage)

                default:
                    context.log.warning("Received unexpected message \(message)")
                }
                return .same
            }
        }
    }

    private static func onRegister(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) throws {
        let key = message._key.asAnyRegistrationKey
        let addressable = message._addressableActorRef

        context.log.debug("Registering \(addressable) under key: \(key)")

        if storage.addRegistration(key: key, ref: addressable) {
            let terminatedCallback = LocalReceptionist.makeRemoveRegistrationCallback(context: context, message: message, storage: storage)
            try LocalReceptionist.startWatcher(ref: addressable, context: context, terminatedCallback: terminatedCallback.invoke(()))

            if let subscribed = storage.subscriptions(forKey: key) {
                let registrations = storage.registrations(forKey: key) ?? []
                for subscription in subscribed {
                    subscription._replyWith(registrations)
                }
            }
        }

        message.replyRegistered()
    }

    private static func onSubscribe(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) throws {
        let anySubscribe = message._asAnySubscribe
        let key = AnyRegistrationKey(from: message._key)

        context.log.debug("Subscribing \(message._asAddressableActorRef) to: \(key)")

        if storage.addSubscription(key: key, subscription: anySubscribe) {
            let terminatedCallback = LocalReceptionist.makeRemoveSubscriptionCallback(context: context, message: message, storage: storage)
            try LocalReceptionist.startWatcher(ref: message._asAddressableActorRef, context: context, terminatedCallback: terminatedCallback.invoke(()))

            anySubscribe.replyWith(storage.registrations(forKey: key) ?? [])
        }
    }

    private static func onLookup(context: ActorContext<Receptionist.Message>, message: _Lookup, storage: Receptionist.Storage) throws {
        if let registered = storage.registrations(forKey: message._key.asAnyRegistrationKey) {
            message.replyWith(registered)
        } else {
            message.replyWith([])
        }
    }

    // TODO: use context aware watch once implemented. See: issue #544
    private static func startWatcher<M>(ref: AddressableActorRef, context: ActorContext<M>, terminatedCallback: @autoclosure @escaping () -> Void) throws {
        let behavior: Behavior<Never> = .setup { context in
            context.watch(ref)
            return .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                if terminated.address == ref.address {
                    terminatedCallback()
                    return .stop
                }
                return .same
            }
        }

        _ = try context.spawn(.anonymous, behavior)
    }

    private static func makeRemoveRegistrationCallback(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        context.makeAsynchronousCallback {
            let remainingRegistrations = storage.removeRegistration(key: message._key.asAnyRegistrationKey, ref: message._addressableActorRef) ?? []

            if let subscribed = storage.subscriptions(forKey: message._key.asAnyRegistrationKey) {
                for subscription in subscribed {
                    subscription._replyWith(remainingRegistrations)
                }
            }
        }
    }

    private static func makeRemoveSubscriptionCallback(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        context.makeAsynchronousCallback {
            storage.removeSubscription(key: message._key.asAnyRegistrationKey, subscription: message._asAnySubscribe)
        }
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
public protocol ReceptionistMessage {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

internal protocol _Register: ReceptionistMessage {
    var _addressableActorRef: AddressableActorRef { get }
    var _key: _RegistrationKey { get }
    func replyRegistered()
}

internal protocol _Lookup: ReceptionistMessage {
    var _key: _RegistrationKey { get }
    func replyWith(_ refs: Set<AddressableActorRef>)
    func replyWith(_ refs: [AddressableActorRef])
}

internal protocol _RegistrationKey {
    var asAnyRegistrationKey: AnyRegistrationKey { get }
    var id: String { get }
    var typeString: FullyQualifiedTypeName { get }
    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `RegistrationKey`
    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef
}

internal enum ReceptionistError: Error {
    case typeMismatch(expected: String)
}

internal struct AnyRegistrationKey: _RegistrationKey, Hashable, Codable {
    var asAnyRegistrationKey: AnyRegistrationKey {
        return self
    }

    var id: String
    var typeString: FullyQualifiedTypeName

    init(from key: _RegistrationKey) {
        self.id = key.id
        self.typeString = key.typeString
    }

    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        return system.personalDeadLetters(type: Any.self, recipient: address).asAddressable()
    }
}

internal protocol _Subscribe: ReceptionistMessage {
    var _key: _RegistrationKey { get }
    var _asAnySubscribe: AnySubscribe { get }
    var _asAddressableActorRef: AddressableActorRef { get }
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
    associatedtype Message

    var key: Receptionist.RegistrationKey<Message> { get }
    var replyTo: ActorRef<Receptionist.Listing<Message>> { get }

    func replyWith(_ refs: Set<AddressableActorRef>)

    var _key: _RegistrationKey { get }
}

internal extension ListingRequest {
    func replyWith(_ refs: Set<AddressableActorRef>) {
        let typedRefs = refs.map {
            key._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    func replyWith(_ refs: [AddressableActorRef]) {
        let typedRefs = refs.map {
            key._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    var _key: _RegistrationKey {
        return self.key
    }
}
