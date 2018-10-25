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

public protocol AnyBehavior {
}

/// A `Behavior` is what executes then an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public enum Behavior<Message>: AnyBehavior {

  /// Defines a behavior that will be executed with an incoming message by its hosting actor.
  case receiveMessage(_ handle: (Message) -> Behavior<Message>) // TODO make them throws?

  /// Defines a behavior that will be executed with an incoming message by its hosting actor.
  /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
  case receive(_ handle: (ActorContext<Message>, Message) -> Behavior<Message>) // TODO make them throws?

  // TODO above is receiveMessage(M -> B)
  // TODO we need receive((Context, M) -> B) as well, leaving it for later

  /// Runs once the actor has been started, also exposing the `ActorContext`
  ///
  /// This can be used to obtain the context, logger or perform actions right when the actor starts
  /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
  case setup(onStart: (ActorContext<Message>) -> Behavior<Message>)

  /// Defines that the same behavior should remain
  case same

  /// A stopped behavior signifies that the actor will cease processing messages (they will be "dropped"),
  /// and the actor itself will stop. Return this behavior to stop your actors.
  case stopped

  /// Causes a message to be assumed unhandled by the runtime.
  /// Unhandled messages are logged by default, and other behaviors may use this information to implement `apply1.orElse(apply2)` style logic.
  /// TODO and their logging rate should be configurable
  case unhandled

  case ignore

//  /// Apply given supervision to behavior
//  /// TODO more docs
//  indirect case supervise(_ behavior: Behavior<Message>, strategy: (Supervision.Failure) -> Supervision.Directive) // TODO I assume this causes us to lose all benefits of being an enum? since `indirect`
//
//  /// Supervise the passed in behavior and return the such supervised behavior.
//  /// The returned behavior will supervised be given supervision decision to any crash of this actor.to behavior
//  public static func supervise(_ behavior: Behavior<Message>, directive: Supervision.Directive) -> Behavior<Message> {
//    return .supervise(behavior) { _ in
//      directive
//    }
//  }

  // MARK: Behavior interpretation utilities

  /// Since we have "special" behaviors like "same" or wrappers intended to
//  internal static func canonicalize<T>(current: Behavior<T>, next: Behavior<T>) -> Behavior<T> {
  @inlinable
  internal func canonicalize(next: Behavior<Message>) -> Behavior<Message> {
    switch next {
    case .same:      return self
    case .unhandled: return self
    case .stopped:   return .stopped
    case .setup:     return FIXME("Not handling setup within other behaviors yet...")
    default:         return next
    }
  }
}

//extension Behavior {
//  static func receiveMessage(_ handle: (Message) -> Void) -> Behavior<Message> {
//    return .receiveMessage({ msg in
//      handle(msg)
//      return .same
//    })
//  }
//}
