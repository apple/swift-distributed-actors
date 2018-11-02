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

import NIOConcurrencyHelpers
import Dispatch

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem {
  // TODO think about if we need ActorSystem to IS-A ActorRef; in Typed we did so, but it complicated the understanding of it to users...
  // it has upsides though, it is then possible to expose additional async APIs on it, without doing any weird things
  // creating an actor them becomes much simpler; it becomes an `ask` and we can avoid locks then (!)

  public let name: String

  // Implementation note:
  // First thing we need to start is the event stream, since is is what powers our logging infrastructure // TODO ;-)
  // so without it we could not log anything.
  let eventStream = "" // FIXME actual implementation

  // let deadLetters: ReceivesMessages<Any> = undefined()

  /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
  private let anonymousNames = AtomicAnonymousNamesGenerator(prefix: "$") // TODO make the $ a constant TODO: where

  private let terminationLock = Lock()
  let dispatcher: MessageDispatcher = try! FixedThreadPool(1)

//  // TODO provider is what abstracts being able to fabricate remote or local actor refs
//  // Implementation note:
//  // We MAY be able to get rid of this (!), I think in Akka it causes some indirections which we may not really need... we'll see
//  private let provider =

  // FIXME should link to the logging infra rather than be ad hoc (init will be tricky, chicken-and-egg ;-))
  // TODO lazy var is unsafe here
  public lazy var log: ActorLogger = ActorLogger(self)
    // the tricky stuff is due to
    // /Users/ktoso/code/sact/Sources/Swift Distributed ActorsActor/ActorSystem.swift:55:16: error: 'self' used before all stored properties are initialized
    // self.log = ActorLogger(self)

  /// Creates a named ActorSystem; The name is useful for debugging cross system communication
  // TODO /// - throws: when configuration requirements can not be fulfilled (e.g. use of OS specific dispatchers is requested on not-matching OS)
  public init(_ name: String) {
    self.name = name
  }

  public convenience init() {
    self.init("ActorSystem")
  }

  // FIXME we don't do any hierarchy right now

  // TODO should we depend on NIO already? I guess so hm they have the TimeAmount... Tho would be nice to split it out maybe
  public func terminate(/* TimeAmount */) -> Awaitable {
    // TODO cause termination here
    return whenTerminated()
  }

  /// - Warning: Blocks current thread until the system has terminated.
  ///            Do not call from within actors or you may deadlock shutting down the system.
  public func whenTerminated() -> Awaitable {
    // return Awaitable(underlyingLock: terminationLock)
    while true {}
    return undefined()
  }
}

/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
// TODO how is it typical to mark an api as "DO NOT CONFORM TO THIS"?
public protocol ActorRefFactory {

  /// Spawn an actor with the given behavior name and props.
  /// - returns
  func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props) -> ActorRef<Message>
}

// MARK: Actor creation

extension ActorSystem: ActorRefFactory {

  /// Spawn a new top-level Actor with the given initial behavior and name.
  public func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props = Props()) -> ActorRef<Message> {
    log.info("Spawning \(behavior), named: [\(name)]")


    // TODO validate name is valid actor name (no / in it etc)
    // TODO move this to the provider perhaps? or some way to share setup logic

    // the "real" actor, the cell that holds the actual "actor"
    let cell: ActorCell<Message> = ActorCell(behavior: behavior, dispatcher: dispatcher)

    // the mailbox of the actor
    let mailbox = NativeMailbox(cell: cell, capacity: Int.max)
    /*switch props.mailbox {
    case let .default(capacity, _):
      mailbox = NativeMailbox(cell: cell, capacity: capacity)
    }*/
    // mailbox.set(cell) // TODO remind myself why it had to be a setter back in Akka

    let refWithCell = ActorRefWithCell(
        path: "/user/\(name)", // TODO this is a mock
        cell: cell,
        mailbox: mailbox
    )

    cell.set(ref: refWithCell)
    refWithCell.sendSystemMessage(.start)

    return refWithCell
  }

  // Implementation note:
  // It is important to have the anonymous one have a "long discouraging name", we want actors to be well named,
  // and devs should only opt into anonymous ones when they are aware that they do so and indeed that's what they want.
  // This is why there should not be default parameter values for actor names
  public func spawnAnonymous<Message>(_ behavior: Behavior<Message>, props: Props = Props()) -> ActorRef<Message> {
    return spawn(behavior, named: self.anonymousNames.nextName(), props: props)
  }
}
