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

  private let name: String

  // Implementation note:
  // First thing we need to start is the event stream, since is is what powers our logging infrastructure // TODO ;-)
  // so without it we could not log anything.
  let eventStream = "" // FIXME actual implementation

  // let deadLetters: ReceivesMessages<Any> = undefined()

  /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
  private let anonymousNames = AtomicAnonymousNamesGenerator(prefix: "$") // TODO make the $ a constant TODO: where

//  // TODO provider is what abstracts being able to fabricate remote or local actor refs
//  // Implementation note:
//  // We MAY be able to get rid of this (!), I think in Akka it causes some indirections which we may not really need... we'll see
//  private let provider =

  /// Creates a named ActorSystem; The name is useful for debugging cross system communication
  // TODO /// - throws: when configuration requirements can not be fulfilled (e.g. use of OS specific dispatchers is requested on not-matching OS)
  public init(_ name: String) {
    self.name = name
  }

  public convenience init() {
    self.init("ActorSystem")
  }

  // FIXME FIXME we don't do any hierarchy right now!!!

  // TODO should we depend on NIO already? I guess so hm they have the TimeAmount... Tho would be nice to split it out maybe
  func terminate(/* TimeAmount */) {
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
    // TODO validate name is valid actor name (no / in it etc)
    // TODO move this to the provider perhaps? or some way to share setup logic

    // what runs the actor:
    let dispatcher: MessageDispatcher = DispatchQueue.global() // look up via props config

    // the "real" actor, the cell that holds the actual "actor"
    let cell: ActorCell<Message> = ActorCell(behavior: behavior, dispatcher: dispatcher)

    // the mailbox of the actor
    let mailbox: Mailbox = DefaultMailbox(cell: cell) // look up via props config
    // mailbox.set(cell) // TODO remind myself why it had to be a setter back in Akka

    let refWithCell = ActorRefWithCell(
        path: "/user/\(name)",
        cell: cell,
        mailbox: mailbox
    ) // TODO we should expose ActorRef

    cell.setRef(refWithCell)
    refWithCell.sendSystem(message: .start)

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
