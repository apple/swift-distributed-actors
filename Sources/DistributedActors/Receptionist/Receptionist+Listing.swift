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
// MARK: "Generic" Receptionist Listing

extension Receptionist {
    /// Response to `Lookup` and `Subscribe` requests.
    /// A listing MAY be empty.
    public struct Listing<Guest: ReceptionistGuest>: Equatable, CustomStringConvertible {
        // let underlying: AnyReceptionistListing
        let underlying: Set<AddressableActorRef>
        let key: Receptionist.RegistrationKey<Guest>

        init(refs: Set<AddressableActorRef>, key: SystemReceptionist.RegistrationKey<Guest>) {
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
            "Receptionist.Listing<\(Guest.self)>(\(self.underlying.map({ $0.address }))"
        }

        public static func == (lhs: Listing<Guest>, rhs: Listing<Guest>) -> Bool {
            lhs.underlying == rhs.underlying
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRef Receptionist Listing

extension Receptionist.Listing where Guest: ReceivesMessages {

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
