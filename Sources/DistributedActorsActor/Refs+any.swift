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

// MARK: Type erasure for ActorRef


/// Type erased form of [[AddressableActorRef]] in order to be used as existential type.
/// This form allows us to check for "is this the same actor?" yet not send messages to it.
public protocol AnyAddressableActorRef {
    var path: ActorPath { get }
    func asHashable() -> AnyHashable

    static func ==(lhs: AnyAddressableActorRef, rhs: AnyAddressableActorRef) -> Bool

}

// Implementation notes:
// Any [[AddressableRef]] is Hashable as well as can be packed as AnyHashable (for type-erasure)
public extension AddressableActorRef {
    public func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }
}

extension ActorRef: AnyAddressableActorRef {
    public func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }
}

extension AnyAddressableActorRef {
    public static func ==(lhs: AnyAddressableActorRef, rhs: AnyAddressableActorRef) -> Bool {
        return lhs.path == rhs.path
    }
}

/// Internal box to type-erase the type details of an [[ActorRef]] yet keep its other properties (e.g. hash-ability)
@usableFromInline internal struct BoxedHashableAnyAddressableActorRef: Hashable, AnyAddressableActorRef {
    private let anyRef: AnyAddressableActorRef

    /// Easiest used with [[ActorRefWithCell]]
    public init<Ref: AnyAddressableActorRef & Hashable>(ref: Ref) {
        self.anyRef = ref
    }

    /// WARNING: Performs an `internal_downcast`
    public init<M>(_ ref: ActorRef<M>) {
        self.init(ref: ref.internal_downcast)
    }

    func hash(into hasher: inout Hasher) {
        self.anyRef.asHashable().hash(into: &hasher)
    }

    static func ==(lhs: BoxedHashableAnyAddressableActorRef, rhs: BoxedHashableAnyAddressableActorRef) -> Bool {
        return lhs.path == rhs.path
    }

    var path: ActorPath {
        return self.anyRef.path
    }

    func asHashable() -> AnyHashable {
        return self.anyRef.asHashable()
    }
}

// MARK: Type erasure for ReceivesMessages

// TODO: maybe, and drop all others?

// MARK: Type erasure for ReceivesSignals

/// Type erased form of [[AddressableActorRef]] in order to be used as existential type.
public protocol AnyReceivesSystemMessages: AnyAddressableActorRef {
    /* internal */ func sendSystemMessage(_ message: SystemMessage)

    var path: ActorPath { get }
    func asHashable() -> AnyHashable
}

internal struct BoxedHashableAnyReceivesSystemMessages: Hashable, AnyReceivesSystemMessages {
    private let anyRef: AnyReceivesSystemMessages

    /// Easiest used with [[ActorRefWithCell]]
    public init<Ref: AnyReceivesSystemMessages & Hashable>(ref: Ref) {
        self.anyRef = ref
    }

    /// WARNING: Performs an `internal_downcast`
    public init<M>(_ ref: ActorRef<M>) {
        self.init(ref: ref.internal_downcast)
    }

    func hash(into hasher: inout Hasher) {
        self.anyRef.asHashable().hash(into: &hasher)
    }

    static func ==(lhs: BoxedHashableAnyReceivesSystemMessages, rhs: BoxedHashableAnyReceivesSystemMessages) -> Bool {
        return lhs.path == rhs.path // TODO: sanity check the path equality assumption
    }

    func sendSystemMessage(_ message: SystemMessage) {
        self.anyRef.sendSystemMessage(message)
    }

    public var path: ActorPath {
        return self.anyRef.path
    }

    func asHashable() -> AnyHashable {
        fatalError("asHashable() has not been implemented")
    }

    /// INTERNAL API: exposes the underlying wrapped anyRef as the expected ActorRef type (or nil if types dont match)
    // TODO make it throw maybe?
    internal func internal_exposeAs<T, R: ActorRef<T>>(_ refType: R.Type) -> R? {
        return self.anyRef as? R
    }
}

/// INTERNAL API: DO NOT TOUCH.
internal extension AnyReceivesSystemMessages {
    
    /// INTERNAL UNSAFE API: unwraps the box, must only be called on AnyReceivesSystemMessages where it is KNOWN guaranteed that it is a box
    internal func internal_exposeBox() -> BoxedHashableAnyReceivesSystemMessages {
        return self as! BoxedHashableAnyReceivesSystemMessages
    }
}

// MARK: Internal boxing helpers

/// INTERNAL API
internal extension ActorRef {

    /// INTERNAL API: Performs downcast, only use when you know what you're doing
    internal func internal_boxAnyReceivesSystemMessages() -> BoxedHashableAnyReceivesSystemMessages {
        return BoxedHashableAnyReceivesSystemMessages(ref: self.internal_downcast)
    }

    /// INTERNAL API: Performs downcast, only use when you know what you're doing
    func internal_boxAnyAddressableActorRef() -> AnyAddressableActorRef {
        return BoxedHashableAnyAddressableActorRef(ref: self.internal_downcast)
    }
}

