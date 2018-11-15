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

// MARK: Internal top generic "capability" abstractions; we'll need those for other "refs"

// TODO designing the cell and ref is so far the most tricky thing I've seen... We want to hide away the ActorRef
//      people should deal with ActorRef<T>; so we can't go protocol for the ActorRef, and we can't go

// MARK: Public API

public protocol AddressableActorRef: Hashable {
  var path: ActorPath { get }
}
extension AddressableActorRef {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    return lhs.path == rhs.path
  }
  public func hash(into hasher: inout Hasher) {
    self.path.hash(into: &hasher)
  }
}

public protocol ReceivesMessages: AddressableActorRef  {
  associatedtype Message
  /// Send message to actor referred to by this [[ActorRef]].
  ///
  /// The symbolic version of "tell" is `!` and should also be pronounced as "tell".
  ///
  /// Note that `tell` is a "fire-and-forget" operation and does not block.
  /// The actor will eventually, asynchronously process the message sent to it.
  func tell(_ message: Message)

}

/// Represents a reference to an actor.
/// All communication between actors is handled _through_ actor refs, which guarantee their isolation remains intact.
public class ActorRef<Message>: ReceivesMessages {

  public var path: ActorPath {
    return undefined()
  }

  public func tell(_ message: Message) {
    return undefined()
  }

  public func adapt<From>(with converter: @escaping (From) -> Message) -> ActorRef<From> {
    return ActorRefAdapter(self, converter)
  }
}

extension ActorRef: CustomStringConvertible, CustomDebugStringConvertible  {
  public var description: String {
    return "ActorRef(\(path))"
  }
  public var debugDescription: String {
    return "ActorRef(\(path.debugDescription)" // TODO: TODO we will need UIDs eventually I think... tho maybe not until we do remoting, since that needs to read a ref from an id
  }
}

// MARK: Internal implementation classes

/// INTERNAL API: Only for use by the actor system itself
// TODO: want to be internal though then https://github.com/apple/swift-distributed-actors/issues/69
public protocol ReceivesSignals: AnyReceivesSignals {
  // TODO fix naming mess with Signal and SystemMessage

  /// INTERNAL API: Only for use by the actor system itself
  ///
  /// Internal API causing an immediate send of a system message to target actor.
  /// System messages are given stronger delivery guarantees in a distributed setting than "user" messages.
  func sendSystemMessage(_ message: SystemMessage)
}

// TODO: we may have to make public to enable inlining? :-( https://github.com/apple/swift-distributed-actors/issues/69
/// INTERNAL API
@usableFromInline
final class ActorRefWithCell<Message>: ActorRef<Message>, ReceivesSignals {

  /// Actors need names. We might want to discuss if we can optimize the names keeping somehow...
  /// The runtime does not care about the names really, and "lookup by name at runtime" has shown to be an anti-pattern in Akka over the years (will explain in depth elsewhere)
  /// Yet they are tremendously useful in debugging and understanding systems: "Which actor is blowing up?! Oh the "transaction-23232" consistently fails; even in presence of not so good log statements etc.
  ///
  /// Since we need the names mostly for debugging; perhaps we can register paths<->ids in some place and fetch them when needed rather than carry them in an ActorRef? -- TODO measure if this would kill logging since contention on the getting names...? tho could be enabled at will or maybe "post processed" even
  ///    -- post processing id -> names could also work; AFAIR aeron logs similarily, to a high performance format, to them obtain full names with a tool out of it; we could also support a debug mode, where names are always around etc...
  /// The thing is that actor refs are EVERYWHERE, so having them light could be beneficial -- TODO measure how much so
  ///
  /// Bottom line: I feel we may gain some performance by straying from the Akka way of carrying the names, yet at the same time, we need to guarantee some way for users to get names; they're incredibly important.

  let _path: ActorPath
  public override var path: ActorPath { return _path }

  let mailbox: Mailbox<Message> // TODO we need to be able to swap it for DeadLetters or find some other way

  // MARK: Internal details; here be dragons
  private let cell: ActorCell<Message>

  public init(path: ActorPath, cell: ActorCell<Message>, mailbox: Mailbox<Message>) {
    self._path = path
    self.cell = cell
    self.mailbox = mailbox
  }

  public override func tell(_ message: Message) { // yes we do want to keep ! and tell, it allows teaching people about the meanings and "how to read !" and also eases the way into other operations
    self.sendMessage(message)
  }

  @usableFromInline
  internal func sendMessage(_ message: Message) {
    // pprint("sendMessage: [\(message)], to: \(self.cell.myself)")
    self.mailbox.sendMessage(envelope: Envelope(payload: message))
  }

  // TODO does not work: `@usableFromInline internal` in a @inlineable method tho it should?
  // /Users/ktoso/code/sact/Sources/Swift Distributed ActorsActor/ActorCell.swift:224:43: error: instance method 'sendSystemMessage' is internal and cannot be referenced from an '@inlinable' function
  // if alreadyDead { self._myselfInACell?.sendSystemMessage(.terminate) }
  // ^
  // /Users/ktoso/code/sact/Sources/Swift Distributed ActorsActor/Refs.swift:117:35: note: instance method 'sendSystemMessage' is not '@usableFromInline' or public
  // @usableFromInline internal func sendSystemMessage(_ message: SystemMessage) {
  //   ^
  @usableFromInline internal func sendSystemMessage(_ message: SystemMessage) {
    // pprint("sendSystemMessage: [\(message)], to: \(self.cell.myself)")
    self.mailbox.sendSystemMessage(message)
  }
}

internal final class ActorRefAdapter<From, To>: ActorRef<From> {
  let ref: ActorRef<To>
  let converter: (From) -> To

  init(_ ref: ActorRef<To>, _ converter: @escaping (From) -> To) {
    self.ref = ref
    self.converter = converter
  }

  override var path: ActorPath {
    return ref.path
  }

  override func tell(_ message: From) {
    ref ! converter(message)
  }
}
