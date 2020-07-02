//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reception

/// Namespace for public messages related to the Receptionist.
public enum Reception {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reception Key

extension Reception {
    /// Used to register and lookup actors in the receptionist.
    /// The key is a combination the Guest's type and an identifier to identify sub-groups of actors of that type.
    ///
    /// The id defaults to "*" which can be used "all actors of that type" (if and only if they registered using this key,
    /// actors which do not opt-into discovery by registering themselves WILL NOT be discovered using this, or any other, key).
    public struct Key<Guest: ReceptionistGuest>: ReceptionKeyProtocol, Codable,
        ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
        CustomStringConvertible {
        let id: String
        var guestType: Any.Type {
            Guest.self
        }

        public init(_ guest: Guest.Type = Guest.self, id: String = "*") {
            self.id = id
        }

        public init(stringLiteral value: StringLiteralType) {
            self.id = value
        }

        internal func _unsafeAsActorRef(_ addressable: AddressableActorRef) -> ActorRef<Guest.Message> {
            if addressable.isRemote() {
                let remotePersonality: RemoteClusterActorPersonality<Guest.Message> = addressable.ref._unsafeGetRemotePersonality(Guest.Message.self)
                return ActorRef(.remote(remotePersonality))
            } else {
                guard let ref = addressable.ref as? ActorRef<Guest.Message> else {
                    fatalError("Type mismatch, expected: [\(String(reflecting: Guest.self))] got [\(addressable)]")
                }

                return ref
            }
        }

        internal func resolve(system: ActorSystem, address: ActorAddress) -> AddressableActorRef {
            let ref: ActorRef<Guest.Message> = system._resolve(context: ResolveContext(address: address, system: system))
            return ref.asAddressable()
        }

        internal var asAnyKey: AnyReceptionKey {
            AnyReceptionKey(self)
        }

        public var description: String {
            "Reception.Key<\(Guest.self)>(id: \(self.id))"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reception Listing

extension Reception {
    /// Response to `Lookup` and `Subscribe` requests.
    /// A listing MAY be empty.
    public struct Listing<Guest: ReceptionistGuest>: Equatable, CustomStringConvertible {
        let underlying: Set<AddressableActorRef>
        let key: Reception.Key<Guest>

        init(refs: Set<AddressableActorRef>, key: Reception.Key<Guest>) {
            // TODO: assert the refs match type?
            self.underlying = refs
            self.key = key
        }

        /// Efficient way to check if a listing is empty.
        public var isEmpty: Bool {
            self.underlying.isEmpty
        }

        /// Efficient way to check check the count of listed actors.
        public var count: Int {
            self.underlying.count
        }

        public var description: String {
            "Reception.Listing<\(Guest.self)>(\(self.underlying.map { $0.address }))"
        }

        public static func == (lhs: Listing<Guest>, rhs: Listing<Guest>) -> Bool {
            lhs.underlying == rhs.underlying
        }
    }
}

extension Reception.Listing where Guest: ReceivesMessages {
    /// Retrieve all listed actor references, mapping them to their appropriate type.
    /// Note that this operation is lazy and has to iterate over all the actors when performing the
    /// iteration.
    ///
    /// Complexity: O(n)
    public var refs: LazyMapSequence<Set<AddressableActorRef>, ActorRef<Guest.Message>> {
        self.underlying.lazy.map { self.key._unsafeAsActorRef($0) }
    }

    var first: ActorRef<Guest.Message>? {
        self.underlying.first.map {
            self.key._unsafeAsActorRef($0)
        }
    }
}

protocol AnyReceptionistListing: ActorMessage {
    // For comparing if two listings are equal
    var refsAsAnyHashable: AnyHashable { get }
}

extension AnyReceptionistListing {
    func unsafeUnwrapAs<T: AnyReceptionistListing>(_ listingType: T.Type) -> T {
        guard let unwrapped = self as? T else {
            fatalError("Type mismatch, expected: [\(T.self)] got [\(type(of: self as Any))]")
        }
        return unwrapped
    }
}

protocol ReceptionistListing: AnyReceptionistListing, Equatable {
    associatedtype Message: ActorMessage

    var refs: Set<ActorRef<Message>> { get }
}

extension ReceptionistListing {
    var refsAsAnyHashable: AnyHashable {
        AnyHashable(self.refs)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reception Registered

extension Reception {
    /// Response to a `Register` message
    public final class Registered<Guest: ReceptionistGuest>: NonTransportableActorMessage, CustomStringConvertible {
        internal let _guest: Guest
        public let key: Reception.Key<Guest>

        public init(_ guest: Guest, key: Reception.Key<Guest>) {
            self._guest = guest
            self.key = key
        }

        public var description: String {
            "Reception.Registered(guest: \(self._guest), key: \(self.key))"
        }
    }
}

extension Reception.Registered where Guest: ReceivesMessages {
    public var ref: ActorRef<Guest.Message> {
        self._guest._ref
    }
}

extension Reception.Registered where Guest: ActorProtocol {
    public var actor: Actor<Guest.Act> {
        .init(ref: self._guest._ref)
    }
}
