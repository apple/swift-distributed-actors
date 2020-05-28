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
    public struct Listing<T>: Equatable, CustomStringConvertible {
        let underlying: AnyReceptionistListing

        public var description: String {
            "\(self.underlying)"
        }

        public static func == (lhs: Listing<T>, rhs: Listing<T>) -> Bool {
            lhs.underlying.refsAsAnyHashable == rhs.underlying.refsAsAnyHashable
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRef Receptionist Listing

extension Receptionist {
    struct ActorRefListing<Message: ActorMessage>: ReceptionistListing, CustomStringConvertible {
        let refs: Set<ActorRef<Message>>

        var description: String {
            "Listing<\(Message.self)>(\(self.refs.map { $0.address }))"
        }
    }
}

extension Receptionist.Listing where T: ActorMessage {
    public typealias Message = T

    public init(refs: Set<ActorRef<Message>>) {
        self.underlying = Receptionist.ActorRefListing(refs: refs)
    }

    public var refs: Set<ActorRef<Message>> {
        self.underlying.unsafeUnwrapAs(Receptionist.ActorRefListing<Message>.self).refs
    }

    var first: ActorRef<Message>? {
        self.refs.first
    }
}
