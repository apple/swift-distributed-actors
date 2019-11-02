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

    internal static let naming: ActorNaming = .unique("receptionist")

    /// Used to register and lookup actors in the receptionist. The key is a combination
    /// of the string id and the message type of the actor.
    public struct GroupIdentifier<Message>: _GroupIdentifier {
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
            return String(reflecting: Message.self)
        }

        internal var boxed: AnyRegistrationKey {
            return AnyRegistrationKey(from: self)
        }
    }

    /// When sent to receptionist will register the specified `ActorRef` under the given `RegistrationKey`
    public struct CheckIn<Message>: _CheckIn {
        public let ref: ActorRef<Message>
        public let group: GroupIdentifier<Message>
        public let replyTo: ActorRef<CheckInConfirmed<Message>>?

        public init(_ ref: ActorRef<Message>, group: GroupIdentifier<Message>, replyTo: ActorRef<CheckInConfirmed<Message>>? = nil) {
            self.ref = ref
            self.group = group
            self.replyTo = replyTo
        }

        internal var _addressableActorRef: AddressableActorRef {
            return AddressableActorRef(self.ref)
        }

        internal var _group: _GroupIdentifier {
            return self.group
        }

        internal func replyCheckedIn() {
            self.replyTo?.tell(Receptionist.CheckInConfirmed(ref: self.ref, group: self.group))
        }
    }

    /// Response to a `CheckIn` message, confirming a successful registration with the receptionist.
    public struct CheckInConfirmed<Message> {
        public let ref: ActorRef<Message>
        public let group: GroupIdentifier<Message>
    }

    /// Used to lookup `ActorRef`s for the given `RegistrationKey`
    public struct Lookup<Message>: ListingRequest, _Lookup {
        public let group: GroupIdentifier<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(group: GroupIdentifier<Message>, replyTo: ActorRef<Listing<Message>>) {
            self.group = group
            self.replyTo = replyTo
        }
    }

    /// Subscribe to periodic updates of the specified key
    public struct Subscribe<Message>: _Subscribe, ListingRequest {
        public let group: GroupIdentifier<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(group: GroupIdentifier<Message>, subscriber: ActorRef<Listing<Message>>) {
            self.group = group
            self.replyTo = subscriber
        }

        internal var _boxed: AnySubscribe {
            return AnySubscribe(subscribe: self)
        }

        var _addressableActorRef: AddressableActorRef {
            return self.replyTo.asAddressable()
        }
    }

    /// A `Listing` contains a set of actor references that are available for the key that was used during `lookup`/`subscribe`.
    /// The listing always contains all actors the receptionist is aware of for the given query, so users need not maintain
    /// their own lists of actors, but can directly store the set as provided by the `refs` field of the listing.
    ///
    /// - SeeAlso: `Receptionist.CheckIn`
    /// - SeeAlso: `Receptionist.Lookup`
    /// - SeeAlso: `Receptionist.Subscribe`
    public struct Listing<Message>: Equatable, CustomStringConvertible {
        public let refs: Set<ActorRef<Message>>
        // FIXME missing group: Group !!!
        public var description: String {
            return "Listing<\(Message.self)>(\(self.refs.map { $0.address }))"
        }
    }

    /// Storage container for a receptionist's registrations and subscriptions
    internal final class Storage {
        internal var _registrations: [AnyRegistrationKey: Set<AddressableActorRef>] = [:]
        private var _subscriptions: [AnyRegistrationKey: Set<AnySubscribe>] = [:]

        func addRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Bool {
            return self.addTo(dict: &self._registrations, key: key, value: ref)
        }

        func removeRegistration(key: AnyRegistrationKey, ref: AddressableActorRef) -> Set<AddressableActorRef>? {
            return self.removeFrom(dict: &self._registrations, key: key, value: ref)
        }

        func registrations(forKey key: AnyRegistrationKey) -> Set<AddressableActorRef>? {
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
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRef + Receptionist

public extension ActorRef where Message == ReceptionistMessage {

    /// Register given actor ref under the reception key, for discovery by other actors (be it local or on other nodes, when clustered).
    ///
    /// - SeeAlso: `subscribe(key:subscriber:)`
    /// - SeeAlso: `lookup(key:subscriber:)`
    func checkIn<M>(_ ref: ActorRef<M>, group: Receptionist.GroupIdentifier<M>, replyTo: ActorRef<Receptionist.CheckInConfirmed<M>>? = nil) {
        self.tell(Receptionist.CheckIn(ref, group: group, replyTo: replyTo))
    }

    /// Used to lookup `ActorRef`s for the given `RegistrationKey`, once.
    ///
    /// Single lookups are inherently racy with new actors checking in with the receptionist,
    /// as such, you may want to use the `subscribe` alternative of interacting with the receptionist,
    /// if you want to be kept always up to date with regards to the list of checked in actors.
    ///
    /// - SeeAlso: `register(key:subscriber:)`
    /// - SeeAlso: `subscribe(key:subscriber:)`
    func lookup<M>(group: Receptionist.GroupIdentifier<M>, replyTo: ActorRef<Receptionist.Listing<M>>) {
        self.lookup(group: group, replyTo: replyTo)
    }

    /// Subscribe to changes in checked-in actors under given `key`.
    /// The `subscriber` actor will be notified with `Receptionist.Listing<M>` messages when new actors register,
    /// leave or die, under the passed in key.
    ///
    /// The listing always contains the *complete* set of actors under the key, for a given moment in time,
    /// thus subscribers need not maintain their own listing, and can rely on the listing provided by the subscription.
    ///
    /// - SeeAlso: `register(key:subscriber:)`
    /// - SeeAlso: `lookup(key:subscriber:)`
    func subscribe<M>(group: Receptionist.GroupIdentifier<M>, subscriber: ActorRef<Receptionist.Listing<M>>) {
        self.tell(Receptionist.Subscribe(group: group, subscriber: subscriber))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorContext + Receptionist

extension ActorContext {

    /// `Receptionist` aware of the current actor context, offering simplified APIs for checking in and looking up actors.
    var receptionist: ContextReceptionist<Message> {
        ContextReceptionist<Message>(context: self)
    }
}


/// An `ActorContext` specific `Receptionist`, simplifying some tasks like checking-in and looking up other actors.
public struct ContextReceptionist<Message> {
    private let context: ActorContext<Message>

    internal init(context: ActorContext<Message>) {
        self.context = context
    }

    internal var ref: ActorRef<Receptionist.Message> {
        return context.system.receptionist
    }

    /// Register `context.myself` under the receptionist `group`, for discovery by other actors (be it local or on other nodes, when clustered).
    ///
    /// - SeeAlso: `subscribe(key:subscriber:)`
    /// - SeeAlso: `lookup(key:subscriber:)`
    func checkIn(group: Receptionist.GroupIdentifier<Message>, timeout: TimeAmount = .effectivelyInfinite) -> AskResponse<Receptionist.CheckInConfirmed<Message>> {
        self.ref.ask(timeout: timeout) {
            Receptionist.CheckIn(self.context.myself, group: group, replyTo: $0)
        }
    }

    // For checking in myself adapted or a subReceive, or even some other actor that we spawned and we want to check in on its behalf.
    @discardableResult
    func checkIn<M>(_ ref: ActorRef<M>, group: Receptionist.GroupIdentifier<M>, timeout: TimeAmount = .effectivelyInfinite) -> AskResponse<Receptionist.CheckInConfirmed<M>> {
        self.ref.ask(timeout: timeout) {
            Receptionist.CheckIn(ref, group: group, replyTo: $0)
        }
    }

    func lookup<M>(group: Receptionist.GroupIdentifier<M>, timeout: TimeAmount = .effectivelyInfinite) -> AskResponse<Receptionist.Listing<M>> {
        self.ref.ask(timeout: timeout) {
            Receptionist.Lookup(group: group, replyTo: $0)
        }
    }

    // TODO: alternate excellent API would be: subscribe(group:) -> Publisher<Listing<M>>
    func subscribe<M>(group: Receptionist.GroupIdentifier<M>, subscriber: ActorRef<Receptionist.Listing<M>>) {
        self.ref.tell(Receptionist.Subscribe(group: group, subscriber: subscriber))
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist Implementations

/// Receptionist for local execution. Does not depend on a cluster being available.
internal enum LocalReceptionist {
    static var behavior: Behavior<Receptionist.Message> {
        return .setup { context in
            let storage = Receptionist.Storage()

            // TODO: implement configurable logging (to log if it gets registers etc)
            // TODO: since all states access all the same state, allocating a local receptionist would result in less passing around storage
            return .receiveMessage { message in
                switch message {
                case let message as _CheckIn:
                    try LocalReceptionist.onCheckIn(context: context, message: message, storage: storage)

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

    private static func onCheckIn(context: ActorContext<Receptionist.Message>, message: _CheckIn, storage: Receptionist.Storage) throws {
        let key = message._group.boxed
        let addressable = message._addressableActorRef

        context.log.debug("Checking in [\(addressable)] under key: \(key)")

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

        message.replyCheckedIn()
    }

    private static func onSubscribe(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) throws {
        let boxedMessage = message._boxed
        let key = AnyRegistrationKey(from: message._group)

        context.log.debug("Subscribing \(message._addressableActorRef) to: \(key)")

        if storage.addSubscription(key: key, subscription: boxedMessage) {
            let terminatedCallback = LocalReceptionist.makeRemoveSubscriptionCallback(context: context, message: message, storage: storage)
            try LocalReceptionist.startWatcher(ref: message._addressableActorRef, context: context, terminatedCallback: terminatedCallback.invoke(()))

            boxedMessage.replyWith(storage.registrations(forKey: key) ?? [])
        }
    }

    private static func onLookup(context: ActorContext<Receptionist.Message>, message: _Lookup, storage: Receptionist.Storage) throws {
        if let registered = storage.registrations(forKey: message._group.boxed) {
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

    private static func makeRemoveRegistrationCallback(context: ActorContext<Receptionist.Message>, message: _CheckIn, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            let remainingRegistrations = storage.removeRegistration(key: message._group.boxed, ref: message._addressableActorRef) ?? []

            if let subscribed = storage.subscriptions(forKey: message._group.boxed) {
                for subscription in subscribed {
                    subscription._replyWith(remainingRegistrations)
                }
            }
        }
    }

    private static func makeRemoveSubscriptionCallback(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            storage.removeSubscription(key: message._group.boxed, subscription: message._boxed)
        }
    }
}

/// Marker protocol for all receptionist messages
///
/// The message implementations are located in `Receptionist.*`
///
/// - SeeAlso:
///     - `Receptionist.Message`
///     - `Receptionist.CheckIn`
///     - `Receptionist.Lookup`
///     - `Receptionist.Subscribe`
public protocol ReceptionistMessage {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

internal protocol _CheckIn: ReceptionistMessage {
    var _addressableActorRef: AddressableActorRef { get }
    var _group: _GroupIdentifier { get }
    func replyCheckedIn()
}

internal protocol _Lookup: ReceptionistMessage {
    var _group: _GroupIdentifier { get }
    func replyWith(_ refs: Set<AddressableActorRef>)
    func replyWith(_ refs: [AddressableActorRef])
}

internal protocol _GroupIdentifier {
    var boxed: AnyRegistrationKey { get }
    var id: String { get }
    var typeString: FullyQualifiedTypeName { get }
    // `resolve` has to be here, because the key is the only thing that knows which
    // type is requested. See implementation in `RegistrationKey`
    func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef
}

internal enum ReceptionistError: Error {
    case typeMismatch(expected: String)
}

internal struct AnyRegistrationKey: _GroupIdentifier, Hashable, Codable {
    var boxed: AnyRegistrationKey {
        return self
    }

    var id: String
    var typeString: FullyQualifiedTypeName

    init(from key: _GroupIdentifier) {
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
    var _group: _GroupIdentifier { get }
    var _boxed: AnySubscribe { get }
    var _addressableActorRef: AddressableActorRef { get }
}

internal struct AnySubscribe: Hashable {
    let address: ActorAddress
    let _replyWith: (Set<AddressableActorRef>) -> Void

    init<M>(subscribe: Receptionist.Subscribe<M>) {
        self.address = subscribe.replyTo.address
        self._replyWith = subscribe.replyWith
    }

    func replyWith(_ refs: Set<AddressableActorRef>) {
        self._replyWith(refs)
    }

    static func == (lhs: AnySubscribe, rhs: AnySubscribe) -> Bool {
        return lhs.address == rhs.address
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.address)
    }
}

internal protocol ListingRequest {
    associatedtype Message

    var group: Receptionist.GroupIdentifier<Message> { get }
    var replyTo: ActorRef<Receptionist.Listing<Message>> { get }

    func replyWith(_ refs: Set<AddressableActorRef>)

    var _group: _GroupIdentifier { get }
}

internal extension ListingRequest {
    func replyWith(_ refs: Set<AddressableActorRef>) {
        let typedRefs = refs.map {
            self.group._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    func replyWith(_ refs: [AddressableActorRef]) {
        let typedRefs = refs.map {
            self.group._unsafeAsActorRef($0)
        }

        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
    }

    var _group: _GroupIdentifier {
        return self.group
    }
}
