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

    internal static let name: String = "receptionist"

    /// Used to register and lookup actors in the receptionist. The key is a combination
    /// of the string id and the message type of the actor.
    public struct RegistrationKey<Message>: _RegistrationKey {
        public let id: String

        public init(_ type: Message.Type, id: String) {
            self.id = id
        }

        internal func _unsafeAsActorRef(_ _ref: BoxedHashableAnyAddressableActorRef) -> ActorRef<Message> {
            return self._unsafeAsActorRef(_ref._exposeUnderlying())
        }

        internal func _unsafeAsActorRef(_ _ref: AnyAddressableActorRef) -> ActorRef<Message> {
            if let remoteRef = _ref as? RemoteActorRef<Any> {
                return remoteRef.cast(to: Message.self)
            }
            guard let ref = _ref as? ActorRef<Message> else {
                fatalError("Type mismatch, expected: [\(String(reflecting: ActorRef<Message>.self))] got [\(_ref)]")
            }

            return ref
        }

        internal func resolve(system: ActorSystem, path: UniqueActorPath) -> AnyReceivesMessages {
            let ref: ActorRef<Message> = system._resolve(context: ResolveContext(path: path, deadLetters: system.deadLetters))
            return ref
        }

        internal var typeString: FullyQualifiedTypeName {
            return String(reflecting: Message.self)
        }

        internal var boxed: AnyRegistrationKey {
            return AnyRegistrationKey(from: self)
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

        internal var _boxHashableAnyAddressableActorRef: BoxedHashableAnyAddressableActorRef {
            return BoxedHashableAnyAddressableActorRef(self.ref)
        }

        internal var _boxAnyReceivesSystemMessages: BoxedHashableAnyReceivesSystemMessages {
            return self.ref._boxAnyReceivesSystemMessages()
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

        public init(key: RegistrationKey<Message>, replyTo: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = replyTo
        }

        internal var _boxed: AnySubscribe {
            return AnySubscribe(subscribe: self)
        }

        var _boxedSystemRef: BoxedHashableAnyReceivesSystemMessages {
            return replyTo._boxAnyReceivesSystemMessages()
        }
    }

    /// Response to `Lookup` and `Subscribe` requests
    public struct Listing<Message>: Equatable {
        public let refs: Set<ActorRef<Message>>
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyRegistrationKey: Set<BoxedHashableAnyAddressableActorRef>] = [:]
        private var _subscriptions: [AnyRegistrationKey: Set<AnySubscribe>] = [:]

        func addRegistration(key: AnyRegistrationKey, ref: BoxedHashableAnyAddressableActorRef) -> Bool {
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyRegistrationKey, ref: BoxedHashableAnyAddressableActorRef) -> Set<BoxedHashableAnyAddressableActorRef>? {
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyRegistrationKey) -> Set<BoxedHashableAnyAddressableActorRef>? {
            return self._registrations[key]
        }

        func addSubscription(key: AnyRegistrationKey, subscription: AnySubscribe) -> Bool {
            return self.addTo(dict: &self._subscriptions, key: key, value: subscription)
        }

        @discardableResult
        func removeSubscription(key: AnyRegistrationKey, subscription: AnySubscribe) -> Set<AnySubscribe>? {
            return self.removeFrom(dict: &self._subscriptions, key: key, value: subscription)
        }

        func subscriptions(forKey key: AnyRegistrationKey) -> Set<AnySubscribe>? {
            return self._subscriptions[key]
        }

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
    }
}

/// Receptionist for local execution. Does not depend on a cluster being available.
internal enum LocalReceptionist {
    static var behavior: Behavior<Receptionist.Message> {
        return .setup { context in
            let storage = Receptionist.Storage()

            return .receiveMessage {
                switch $0 {
                case let message as _Register:
                    try LocalReceptionist.onRegister(context: context, message: message, storage: storage)

                case let message as _Lookup:
                    try LocalReceptionist.onLookup(context: context, message: message, storage: storage)

                case let message as _Subscribe:
                    try LocalReceptionist.onSubscribe(context: context, message: message, storage: storage)

                default:
                    context.log.warning("Received unexpected message \($0)")
                }
                return .same
            }
        }
    }

    private static func onRegister(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) throws {
        let key = message._key.boxed
        if storage.addRegistration(key: key, ref: message._boxHashableAnyAddressableActorRef) {
            let terminatedCallback = LocalReceptionist.makeRemoveRegistrationCallback(context: context, message: message, storage: storage)
            try LocalReceptionist.startWatcher(ref: message._boxAnyReceivesSystemMessages, context: context, terminatedCallback: terminatedCallback.invoke(()))

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
        let boxedMessage = message._boxed
        let key = AnyRegistrationKey(from: message._key)
        if storage.addSubscription(key: key, subscription: boxedMessage) {
            let terminatedCallback = LocalReceptionist.makeRemoveSubscriptionCallback(context: context, message: message, storage: storage)
            try LocalReceptionist.startWatcher(ref: message._boxedSystemRef, context: context, terminatedCallback: terminatedCallback.invoke(()))

            boxedMessage.replyWith(storage.registrations(forKey: key) ?? [])
        }
    }

    private static func onLookup(context: ActorContext<Receptionist.Message>, message: _Lookup, storage: Receptionist.Storage) throws {
        if let registered = storage.registrations(forKey: message._key.boxed) {
            message.replyWith(registered)
        } else {
            message.replyWith([])
        }
    }

    // TODO: use context aware watch once implemented. See: https://github.com/apple/swift-distributed-actors/issues/544
    private static func startWatcher<M>(ref: BoxedHashableAnyReceivesSystemMessages, context: ActorContext<M>, terminatedCallback: @autoclosure @escaping () -> Void) throws {
        let behavior: Behavior<Never> = .setup { context in
            context.watch(ref)
            return .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                if terminated.path == ref.path {
                    terminatedCallback()
                    return .stopped
                }
                return .ignore
            }
        }

        _ = try context.spawnAnonymous(behavior)
    }

    private static func makeRemoveRegistrationCallback(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            let remainingRegistrations = storage.removeRegistration(key: message._key.boxed, ref: message._boxHashableAnyAddressableActorRef) ?? []

            if let subscribed = storage.subscriptions(forKey: message._key.boxed) {
                for subscription in subscribed {
                    subscription._replyWith(remainingRegistrations)
                }
            }
        }
    }

    private static func makeRemoveSubscriptionCallback(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            storage.removeSubscription(key: message._key.boxed, subscription: message._boxed)
        }
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
    var _boxHashableAnyAddressableActorRef: BoxedHashableAnyAddressableActorRef { get }
    var _boxAnyReceivesSystemMessages: BoxedHashableAnyReceivesSystemMessages { get }
    var _key: _RegistrationKey { get }
    func replyRegistered()
}

internal protocol _Lookup: ReceptionistMessage {
    var _key: _RegistrationKey { get }
    func replyWith(_ refs: Set<BoxedHashableAnyAddressableActorRef>)
    func replyWith(_ refs: [AnyReceivesMessages])
}

internal protocol _RegistrationKey {
    var boxed: AnyRegistrationKey { get }
    var id: String { get }
    var typeString: FullyQualifiedTypeName { get }
    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `RegistrationKey`
    func resolve(system: ActorSystem, path: UniqueActorPath) -> AnyReceivesMessages
}

internal enum ReceptionistError: Error {
    case typeMismatch(expected: String)
}

internal struct AnyRegistrationKey: _RegistrationKey, Hashable, Codable {
    var boxed: AnyRegistrationKey {
        return self
    }

    var id: String
    var typeString: FullyQualifiedTypeName

    init(from key: _RegistrationKey) {
        self.id = key.id
        self.typeString = key.typeString
    }

    func resolve(system: ActorSystem, path: UniqueActorPath) -> AnyReceivesMessages {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        return system.deadLetters
    }
}

internal protocol _Subscribe: ReceptionistMessage {
    var _key: _RegistrationKey { get }
    var _boxed: AnySubscribe { get }
    var _boxedSystemRef: BoxedHashableAnyReceivesSystemMessages { get }
}

internal struct AnySubscribe: Hashable {
    let path: UniqueActorPath
    let _replyWith: (Set<BoxedHashableAnyAddressableActorRef>) -> Void

    init<M>(subscribe: Receptionist.Subscribe<M>) {
        self.path = subscribe.replyTo.path
        self._replyWith = subscribe.replyWith
    }

    func replyWith(_ refs: Set<BoxedHashableAnyAddressableActorRef>) {
        self._replyWith(refs)
    }

    static func == (lhs: AnySubscribe, rhs: AnySubscribe) -> Bool {
        return lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.path)
    }
}

internal protocol ListingRequest {
    associatedtype Message

    var key: Receptionist.RegistrationKey<Message> { get }
    var replyTo: ActorRef<Receptionist.Listing<Message>> { get }

    func replyWith(_ refs: Set<BoxedHashableAnyAddressableActorRef>)

    var _key: _RegistrationKey { get }
}

internal extension ListingRequest {
    func replyWith(_ refs: Set<BoxedHashableAnyAddressableActorRef>) {
        let typedRefs = refs.map {
            key._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    func replyWith(_ refs: [AnyReceivesMessages]) {
        let typedRefs = refs.map {
            key._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    var _key: _RegistrationKey {
        return self.key
    }
}
