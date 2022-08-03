//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DistributedReception

/// Namespace for public messages related to the DistributedReceptionist.
public enum DistributedReception {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DistributedReception Key

extension DistributedReception {
    /// Used to register and lookup actors in the receptionist.
    /// The key is a combination the Guest's type and an identifier to identify sub-groups of actors of that type.
    ///
    /// The id defaults to "*" which can be used "all actors of that type" (if and only if they registered using this key,
    /// actors which do not opt-into discovery by registering themselves WILL NOT be discovered using this, or any other, key).
    public struct Key<Guest: DistributedActor>: Codable, Sendable,
        ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
        CustomStringConvertible where Guest.ActorSystem == ClusterSystem
    {
        public let id: String
        public var guestType: Any.Type {
            Guest.self
        }

        public init(_ guest: Guest.Type = Guest.self, id: String = "*") {
            self.id = id
        }

        public init(stringLiteral value: StringLiteralType) {
            self.id = value
        }

        internal func resolve(system: ClusterSystem, id: ActorID) -> _AddressableActorRef {
            let ref: _ActorRef<InvocationMessage> = system._resolve(context: _ResolveContext(id: id, system: system))
            return ref.asAddressable
        }

        internal var asAnyKey: AnyDistributedReceptionKey {
            AnyDistributedReceptionKey(self)
        }

        public var description: String {
            "DistributedReception.Key<\(String(reflecting: Guest.self))>(id: \(self.id))"
        }
    }
}

struct AnyDistributedReceptionKey: Sendable, Codable, Hashable, CustomStringConvertible {
    enum CodingKeys: CodingKey {
        case id
        case guestTypeManifest
    }

    let id: String
    let guestType: Any.Type

    init<Guest>(_ key: DistributedReception.Key<Guest>) {
        self.id = key.id
        self.guestType = Guest.self
    }

    func resolve(system: ClusterSystem, id: ActorID) -> _AddressableActorRef {
        // Since we don't have the type information here, we can't properly resolve
        // and the only safe thing to do is to return `deadLetters`.
        system.personalDeadLetters(type: Never.self, recipient: id).asAddressable
    }

    var asAnyKey: AnyDistributedReceptionKey {
        self
    }

    public var description: String {
        "\(Self.self)<\(reflecting: self.guestType)>(\(self.id))"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(ObjectIdentifier(self.guestType))
    }

    public static func == (lhs: AnyDistributedReceptionKey, rhs: AnyDistributedReceptionKey) -> Bool {
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

//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: DistributedReception Listing
//
// extension DistributedReception {
//    /// Response to `Lookup` and `Subscribe` requests.
//    /// A listing MAY be empty.
//    public struct Listing<Guest: _ReceptionistGuest>: Equatable, CustomStringConvertible {
//        let underlying: Set<_AddressableActorRef>
//        let key: DistributedReception.Key<Guest>
//
//        init(refs: Set<_AddressableActorRef>, key: DistributedReception.Key<Guest>) {
//            // TODO: assert the refs match type?
//            self.underlying = refs
//            self.key = key
//        }
//
//        /// Efficient way to check if a listing is empty.
//        public var isEmpty: Bool {
//            self.underlying.isEmpty
//        }
//
//        /// Efficient way to check check the count of listed actors.
//        public var count: Int {
//            self.underlying.count
//        }
//
//        public var description: String {
//            "DistributedReception.Listing<\(Guest.self)>(\(self.underlying.map { $0.id }))"
//        }
//
//        public static func == (lhs: Listing<Guest>, rhs: Listing<Guest>) -> Bool {
//            lhs.underlying == rhs.underlying
//        }
//    }
// }

// extension DistributedReception.Listing where Guest: DistributedActor {
//    /// Retrieve all listed actor references, mapping them to their appropriate type.
//    /// Note that this operation is lazy and has to iterate over all the actors when performing the
//    /// iteration.
//    public var refs: LazyMapSequence<Set<_AddressableActorRef>, _ActorRef<Guest.Message>> {
//        self.underlying.lazy.map { self.key._unsafeAsActorRef($0) }
//    }
//
//    var firstRef: _ActorRef<Guest.Message>? {
//        self.underlying.first.map {
//            self.key._unsafeAsActorRef($0)
//        }
//    }
//
//    public var first: _ActorRef<Guest.Message>? {
//        self.underlying.first.map {
//            self.key._unsafeAsActorRef($0)
//        }
//    }
//
//    public func first(where matches: (ActorID) -> Bool) -> _ActorRef<Guest.Message>? {
//        self.underlying.first {
//            let ref: _ActorRef<Guest.Message> = self.key._unsafeAsActorRef($0)
//            return matches(ref.id)
//        }.map {
//            self.key._unsafeAsActorRef($0)
//        }
//    }
//
//    /// Returns the first actor from the listing whose name matches the passed in `name` parameter.
//    ///
//    /// Special handling is applied to message adapters (e.g. `/uses/example/two/$messageAdapter` in which case the last segment is ignored).
//    public func first(named name: String) -> _ActorRef<Guest.Message>? {
//        self.underlying.first {
//            $0.path.name == name ||
//                ($0.path.segments.last?.value == "$messageAdapter" && $0.path.segments.dropLast(1).last?.value == name)
//        }.map {
//            self.key._unsafeAsActorRef($0)
//        }
//    }
// }
//
// protocol AnyReceptionistListing: Codable {
//    // For comparing if two listings are equal
//    var refsAsAnyHashable: AnyHashable { get }
// }
//
// extension AnyReceptionistListing {
//    func unsafeUnwrapAs<T: AnyReceptionistListing>(_ listingType: T.Type) -> T {
//        guard let unwrapped = self as? T else {
//            fatalError("Type mismatch, expected: [\(T.self)] got [\(type(of: self as Any))]")
//        }
//        return unwrapped
//    }
// }
//
// protocol ReceptionistListing: AnyReceptionistListing, Equatable {
//    associatedtype Message: Codable
//
//    var refs: Set<_ActorRef<Message>> { get }
// }
//
// extension ReceptionistListing {
//    var refsAsAnyHashable: AnyHashable {
//        AnyHashable(self.refs)
//    }
// }

//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: DistributedReception Registered
//
// extension DistributedReception {
//    /// Response to a `Register` message
//    public final class Registered<Guest: _ReceptionistGuest>: _NotActuallyCodableMessage, CustomStringConvertible {
//        internal let _guest: Guest
//        public let key: DistributedReception.Key<Guest>
//
//        public init(_ guest: Guest, key: DistributedReception.Key<Guest>) {
//            self._guest = guest
//            self.key = key
//        }
//
//        public var description: String {
//            "DistributedReception.Registered(guest: \(self._guest), key: \(self.key))"
//        }
//    }
// }
//
// extension DistributedReception.Registered where Guest: _ReceivesMessages {
//    internal var ref: _ActorRef<Guest.Message> {
//        self._guest._ref
//    }
// }
//
// extension DistributedReception.Registered where Guest: DistributedActor {
//    public var actor: Guest {
//        let system = self._guest.actorTransport._forceUnwrapActorSystem
//
//        return try! Guest.resolve(id: self._guest._ref.asAddressable.asActorSystem.ActorID, using: system) // FIXME: cleanup these APIs, should never need throws, resolve earlier
//    }
// }
