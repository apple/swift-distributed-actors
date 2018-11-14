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
internal struct BoxedHashableAnyAddressableActorRef: Hashable, AnyAddressableActorRef {
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

// TODO maybe, and drop all others?

// MARK: Type erasure for ReceivesSignals

/// Type erased form of [[AddressableActorRef]] in order to be used as existential type.
public protocol AnyReceivesSignals {
  /* internal */ func sendSystemMessage(_ message: SystemMessage)

  var path: ActorPath { get }
  func asHashable() -> AnyHashable
}

internal struct BoxedHashableAnyReceivesSignals: Hashable, AnyReceivesSignals {
  private let anyRef: AnyReceivesSignals

  /// Easiest used with [[ActorRefWithCell]]
  public init<Ref: AnyReceivesSignals & Hashable>(ref: Ref) {
    self.anyRef = ref
  }

  /// WARNING: Performs an `internal_downcast`
  public init<M>(_ ref: ActorRef<M>) {
    self.init(ref: ref.internal_downcast)
  }

  func hash(into hasher: inout Hasher) {
    self.anyRef.asHashable().hash(into: &hasher)
  }

  static func ==(lhs: BoxedHashableAnyReceivesSignals, rhs: BoxedHashableAnyReceivesSignals) -> Bool {
    return lhs.path == rhs.path // TODO sanity check the path equality assumption
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
}

/// INTERNAL API: DO NOT TOUCH.
internal extension AnyReceivesSignals {
  /// INTERNAL API: unwraps the box
  internal func internal_exposeBox() -> BoxedHashableAnyReceivesSignals {
    return self as! BoxedHashableAnyReceivesSignals
  }
}

// MARK: internal ActorRefWithCell conformances

extension ActorRefWithCell {
  
}


