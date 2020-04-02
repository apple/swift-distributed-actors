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

    // Implementation notes: // TODO: Intercept messages to register at remote receptionist, and hande locally?
    // Receptionist messages are a bit special. Technically we CAN allow sending them over to remotes
    // but we do not today. Generally though, for example registering with a remote's receptionist is a "bad idea"™
    // it is more efficient to register on the local one, so what we could do, is when sending to a remote receptionist,
    // is to detect that and rather send to the local one.

    internal static let naming: ActorNaming = .unique("receptionist")

    /// Used to register and lookup actors in the receptionist. The key is a combination
    /// of the string id and the message type of the actor.
    public class RegistrationKey<Message: ActorMessage>: _RegistrationKey, CustomStringConvertible, ExpressibleByStringLiteral {
        public init(_ type: Message.Type, id: String) {
            super.init(id: id, typeHint: _typeName(Message.self as Any.Type))
        }

        public required init(stringLiteral value: StringLiteralType) {
            super.init(id: value, typeHint: _typeName(Message.self as Any.Type))
        }

        internal func _unsafeAsActorRef(_ addressable: AddressableActorRef) -> ActorRef<Message> {
            if addressable.isRemote() {
                let remoteWellTypedPersonality: RemotePersonality<Message> = addressable.ref._unsafeGetRemotePersonality(Message.self)
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
    public class Register<Message: ActorMessage>: _Register {
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
            throw SerializationError.notTransportableMessage(type: "")
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
    public class Registered<Message: ActorMessage>: NotTransportableActorMessage, CustomStringConvertible {
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
    public class Lookup<Message: ActorMessage>: _Lookup, ListingRequest, CustomStringConvertible {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, replyTo: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = replyTo
            super.init(_key: key)
        }

        required init(from decoder: Decoder) throws {
            throw SerializationError.notTransportableMessage(type: "\(Self.self)")
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
    public class Subscribe<Message: ActorMessage>: _Subscribe, ListingRequest, CustomStringConvertible {
        public let key: RegistrationKey<Message>
        public let replyTo: ActorRef<Listing<Message>>

        public init(key: RegistrationKey<Message>, subscriber: ActorRef<Listing<Message>>) {
            self.key = key
            self.replyTo = subscriber
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.notTransportableMessage(type: "\(Self.self)")
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

    /// Response to `Lookup` and `Subscribe` requests
    /// // TODO: can be made Codable
    public struct Listing<Message: ActorMessage>: ActorMessage, Equatable, CustomStringConvertible {
        public let refs: Set<ActorRef<Message>>
        public var description: String {
            "Listing<\(Message.self)>(\(self.refs.map { $0.address }))"
        }

        var first: ActorRef<Message>? {
            self.refs.first
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
                pprint("regs = \(regs)")
                pprint("prunedRegs = \(prunedRegs)")
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
public class ReceptionistMessage: ActorMessage {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: internal untyped protocols

internal typealias FullyQualifiedTypeName = String

// TODO: Receptionist._Register
public class _Register: ReceptionistMessage, NotTransportableActorMessage, CustomStringConvertible {
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
public class _Lookup: ReceptionistMessage, NotTransportableActorMessage {
    let _key: _RegistrationKey

    init(_key: _RegistrationKey) {
        self._key = _key
        super.init()
    }

    required init(from decoder: Decoder) throws {
        throw SerializationError.notTransportableMessage(type: "\(Self.self)")
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

public class _Subscribe: ReceptionistMessage, NotTransportableActorMessage {
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
        throw SerializationError.notTransportableMessage(type: "\(Self.self)")
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
    associatedtype Message: ActorMessage

    var key: Receptionist.RegistrationKey<Message> { get }
    var _key: _RegistrationKey { get }

    var replyTo: ActorRef<Receptionist.Listing<Message>> { get }

    func replyWith(_ refs: Set<AddressableActorRef>)
}

// TODO: uncomment if you like compiler crashes
//
// Assertion failed: (!isInvalid()), function getRequirement, file /Users/buildnode/jenkins/workspace/oss-swift-5.1-package-osx/swift/lib/AST/ProtocolConformance.cpp, line 77.
// Stack dump:
// 0.	Program arguments: /Library/Developer/Toolchains/swift-5.1.4-RELEASE.xctoolchain/usr/bin/swift -frontend -c -filelist /var/folders/wh/s6r_3sk96596_wztm8w1pgfw0000gn/T/sources-7fc66e -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterSettings.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterShell.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/HandshakeStateMachine.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Leadership.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/NodeDeathWatcher.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/ClusterReceptionistSettings.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/OperationLogClusterReceptionist+Serialization.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/OperationLogClusterReceptionist.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIM.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Transport/TransportPipelines.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/DeadLetters.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/ProcessIsolated.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Receptionist.swift -primary-file /Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization.swift -supplementary-output-file-map /var/folders/wh/s6r_3sk96596_wztm8w1pgfw0000gn/T/supplementaryOutputs-c137ef -target x86_64-apple-macosx10.10 -enable-objc-interop -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.15.sdk -I /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug -I /Users/ktoso/code/actors/.build/checkouts/swift-backtrace/Sources/CBacktrace/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSLShims/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio/Sources/CNIOSHA1/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio/Sources/CNIOAtomics/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio/Sources/CNIODarwin/include -I /Users/ktoso/code/actors/.build/checkouts/swift-nio/Sources/CNIOLinux/include -I /Users/ktoso/code/actors/Sources/CDistributedActorsMailbox/include -I /Users/ktoso/code/actors/Sources/CDistributedActorsAtomics/include -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -enable-testing -g -module-cache-path /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/ModuleCache -swift-version 5 -Onone -D SWIFT_PACKAGE -D DEBUG -color-diagnostics -enable-anonymous-context-mangled-names -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CBacktrace.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIOBoringSSLShims.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIOBoringSSL.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIOSHA1.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIOAtomics.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIODarwin.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CNIOLinux.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CDistributedActorsMailbox.build/module.modulemap -Xcc -fmodule-map-file=/Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/CDistributedActorsAtomics.build/module.modulemap -parse-as-library -module-name DistributedActors -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/ClusterSettings.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/ClusterShell.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/HandshakeStateMachine.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/Leadership.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/NodeDeathWatcher.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/Reception/ClusterReceptionistSettings.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/Reception/OperationLogClusterReceptionist+Serialization.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/Reception/OperationLogClusterReceptionist.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/SWIM/SWIM.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Cluster/Transport/TransportPipelines.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/DeadLetters.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/ProcessIsolated/ProcessIsolated.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Receptionist.swift.o -o /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/DistributedActors.build/Serialization/Serialization.swift.o -index-store-path /Users/ktoso/code/actors/.build/x86_64-apple-macosx/debug/index/store -index-system-modules
// 1.	Contents of /var/folders/wh/s6r_3sk96596_wztm8w1pgfw0000gn/T/sources-7fc66e:
// ---
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorAddress.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorContext.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorLogging.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorMessage+Protobuf.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorMessage.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorNaming.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorRef+Ask.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorRefProvider.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorShell+Children.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorShell+Defer.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorShell.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorSystem.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorSystemSettings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ActorTransport.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Adapters.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/AffinityThreadPool.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/AsyncResult.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Await.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Backoff.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Behaviors.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/CRDT+Logging.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/CRDT+Replication.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/CRDT+ReplicatorInstance.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/CRDT+ReplicatorShell.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/CRDT.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Protobuf/CRDT+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Protobuf/CRDT.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Protobuf/CRDT.Envelope+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Protobuf/CRDTReplication+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Protobuf/CRDTReplication.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+Any.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+GCounter.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+LWWMap.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+LWWRegister.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+ORMap.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+ORMultiMap.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+ORSet.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+StateBased.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CRDT/Types/CRDT+Versioning.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Clocks/LamportClock.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Clocks/Protobuf/VersionVector+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Clocks/Protobuf/VersionVector.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Clocks/VersionVector.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Association.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Chaos/LossyMessagesHandler.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Cluster+Event.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Cluster+Gossip.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Cluster+Member.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Cluster+Membership.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterControl.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterEventStream.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterSettings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterShell+LeaderActions.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterShell+Logging.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterShell.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/ClusterShellState.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Downing/DowningSettings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Downing/DowningStrategy.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Downing/TimeoutBasedDowningStrategy.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/HandshakeStateMachine.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Leadership.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/NodeDeathWatcher.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/Cluster+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/Cluster.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/ClusterEvents+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/ClusterEvents.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/Membership+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Protobuf/Membership.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/ClusterReceptionistSettings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/OperationLog.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/OperationLogClusterReceptionist+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Reception/OperationLogClusterReceptionist.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/Protobuf/SWIM+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/Protobuf/SWIM.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIM.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIMInstance+Logging.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIMInstance.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIMSettings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SWIM/SWIMShell.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/SystemMessages+Redelivery.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Transport/ActorRef+RemotePersonality.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Transport/TransportPipelines.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Cluster/Transport/WireMessages.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Condition.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CountDownLatch.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/CustomStringInterpolations.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/DeadLetters.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/DeathWatch.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Dispatchers.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/EventStream.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/FixedThreadPool.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actor+Codable.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actor+Context+Receptionist.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actor+Context.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actor.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actorable+ActorContext.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actorable+ActorSystem.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/Actorable.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/ActorableOwned.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/GenActors/ClusterControl+ActorableOwnedMembership.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Heap.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/ActorInstrumentation.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/ActorMailboxInstrumentation.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/ActorTransportInstrumentation.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/os_signpost/ActorInstrumentation+os_signpost.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/os_signpost/ActorTransportInstrumentation+os_signpost.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Instrumentation/os_signpost/InstrumentationProvider+os_signpost.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/LinkedBlockingQueue.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/MPSCLinkedQueue.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Mailbox.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Metrics/ActorSystem+Metrics.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Metrics/ActorSystemSettings+Metrics.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Metrics/CoreMetrics+MetricsPNCounter.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/NIO+Extensions.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Pattern/ConvergentGossip+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Pattern/ConvergentGossip.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Pattern/PeriodicBroadcast.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Pattern/WorkerPool.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Plugins/ActorSystem+Plugins.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Plugins/ActorSystemSettings+Plugins.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/POSIXProcessUtils.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/PollingParentMonitoringFailureDetector.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/ProcessCommander.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/ProcessIsolated+Supervision.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/ProcessIsolated/ProcessIsolated.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Props.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/ActorAddress+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/ActorAddress.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/ProtobufMessage+Extensions.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/SystemMessages+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/SystemMessages.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/WireProtocol+Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Protobuf/WireProtocol.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Receptionist+Local.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Receptionist.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Refs+any.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Refs.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/RingBuffer.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Scheduler.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Protobuf/Serialization.pb.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+BuiltIn.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Codable.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Context.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+SerializerID.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Serializers+Codable.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Serializers+Protobuf.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Serializers.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization+Settings.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/Serialization.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Serialization/SerializationPool.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Signals.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/StashBuffer.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Supervision.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/SystemMessages.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Thread.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Time.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/TimeSpec.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Timers.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/Version.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/locks.swift
/// Users/ktoso/code/actors/Sources/DistributedActors/utils.swift
// ---
// 2.	While emitting IR SIL function "@$s17DistributedActors12ReceptionistO9SubscribeCy_qd__GAA14ListingRequestA2aGP4_keyAA16_RegistrationKeyCvgTW".
// for getter for _key (at /Users/ktoso/code/actors/Sources/DistributedActors/Receptionist.swift:490:9)
// 0  swift                    0x000000010c667ff5 llvm::sys::PrintStackTrace(llvm::raw_ostream&) + 37
// 1  swift                    0x000000010c6672e5 llvm::sys::RunSignalHandlers() + 85
// 2  swift                    0x000000010c6685d8 SignalHandler(int) + 264
// 3  libsystem_platform.dylib 0x00007fff6824e5fd _sigtramp + 29
// 4  libdyld.dylib            0x00007fff6805478f dyldGlobalLockRelease() + 0
// 5  libsystem_c.dylib        0x00007fff68124808 abort + 120
// 6  libsystem_c.dylib        0x00007fff68123ac6 err + 0
// 7  swift                    0x000000010cac7e71 swift::ProtocolConformanceRef::getRequirement() const (.cold.1) + 33
// 8  swift                    0x0000000109b81da6 swift::ProtocolConformanceRef::getRequirement() const + 38
// 9  swift                    0x0000000108e65d32 void llvm::function_ref<void (unsigned int, swift::CanType, llvm::Optional<swift::ProtocolConformanceRef>)>::callback_fn<swift::irgen::FulfillmentMap::searchNominalTypeMetadata(swift::irgen::IRGenModule&, swift::CanType, swift::MetadataState, unsigned int, swift::irgen::MetadataPath&&, swift::irgen::FulfillmentMap::InterestingKeysCallback const&)::$_1>(long, unsigned int, swift::CanType, llvm::Optional<swift::ProtocolConformanceRef>) + 1138
// 10 swift                    0x0000000108f31870 swift::irgen::GenericTypeRequirements::enumerateFulfillments(swift::irgen::IRGenModule&, swift::SubstitutionMap, llvm::function_ref<void (unsigned int, swift::CanType, llvm::Optional<swift::ProtocolConformanceRef>)>) + 240
// 11 swift                    0x0000000108e64f45 swift::irgen::FulfillmentMap::searchNominalTypeMetadata(swift::irgen::IRGenModule&, swift::CanType, swift::MetadataState, unsigned int, swift::irgen::MetadataPath&&, swift::irgen::FulfillmentMap::InterestingKeysCallback const&) + 245
// 12 swift                    0x0000000108e64cf8 swift::irgen::FulfillmentMap::searchTypeMetadata(swift::irgen::IRGenModule&, swift::CanType, swift::irgen::IsExact_t, swift::MetadataState, unsigned int, swift::irgen::MetadataPath&&, swift::irgen::FulfillmentMap::InterestingKeysCallback const&) + 840
// 13 swift                    0x0000000108fc0442 swift::irgen::LocalTypeDataCache::addAbstractForTypeMetadata(swift::irgen::IRGenFunction&, swift::CanType, swift::irgen::IsExact_t, swift::irgen::MetadataResponse) + 114
// 14 swift                    0x0000000108fc03b5 swift::irgen::IRGenFunction::bindLocalTypeDataFromTypeMetadata(swift::CanType, swift::irgen::IsExact_t, llvm::Value*, swift::MetadataState) + 277
// 15 swift                    0x0000000108f30334 swift::irgen::emitPolymorphicParameters(swift::irgen::IRGenFunction&, swift::SILFunction&, swift::irgen::Explosion&, swift::irgen::WitnessMetadata*, llvm::function_ref<llvm::Value* (unsigned int)> const&) + 820
// 16 swift                    0x0000000108f8c1a0 swift::irgen::IRGenModule::emitSILFunction(swift::SILFunction*) + 5952
// 17 swift                    0x0000000108ea942b swift::irgen::IRGenerator::emitLazyDefinitions() + 1243
// 18 swift                    0x0000000108f676b5 performIRGeneration(swift::IRGenOptions&, swift::ModuleDecl*, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule> >, llvm::StringRef, swift::PrimarySpecificPaths const&, llvm::LLVMContext&, swift::SourceFile*, llvm::GlobalVariable**) + 1477
// 19 swift                    0x0000000108f67ae2 swift::performIRGeneration(swift::IRGenOptions&, swift::SourceFile&, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule> >, llvm::StringRef, swift::PrimarySpecificPaths const&, llvm::LLVMContext&, llvm::GlobalVariable**) + 82
// 20 swift                    0x0000000108e15827 performCompile(swift::CompilerInstance&, swift::CompilerInvocation&, llvm::ArrayRef<char const*>, int&, swift::FrontendObserver*, swift::UnifiedStatsReporter*) + 13975
// 21 swift                    0x0000000108e1126a swift::performFrontend(llvm::ArrayRef<char const*>, char const*, void*, swift::FrontendObserver*) + 3002
// 22 swift                    0x0000000108db9d18 main + 696
// 23 libdyld.dylib            0x00007fff68055cc9 start + 1
// 24 libdyld.dylib            0x000000000000007f start + 2549785527
//
// internal extension ListingRequest {
//
/// /    func replyWith(_ refs: Set<AddressableActorRef>) {
/// /        let typedRefs = refs.map { ref in
/// /            key._unsafeAsActorRef(ref)
/// /        }
/// /
/// /        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
/// /    }
//
//    func replyWith(_ refs: [AddressableActorRef]) {
//        let typedRefs = refs.map {
//            key._unsafeAsActorRef($0)
//        }
//
//        replyTo.tell(Receptionist.Listing(refs: Set(typedRefs)))
//    }
//
//    var _key: _RegistrationKey {
//        return self.key
//    }
// }
