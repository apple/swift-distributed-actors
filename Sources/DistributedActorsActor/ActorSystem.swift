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

import Atomics

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
public final class ActorSystem {

  private let anonymousNames = AnonymousNamesGenerator(prefix: "$") // TODO make the $ a constant TODO: where

  private let name: String

  /// Creates a named ActorSystem; The name is useful for debugging cross system communication
  // TODO /// - throws: when configuration requirements can not be fulfilled (e.g. use of OS specific dispatchers is requested on not-matching OS)
  public init(_ name: String) {
    self.name = name
  }

  public convenience init() {
    self.init("ActorSystem")
  }

}

// TODO: Not sure yet how minimal we need to keep this API; (in Akka it has a lot of historical baggage, trying to keep this minimal)
public protocol ActorRefFactory {

  func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props) -> ActorRef<Message>
}

extension ActorSystem: ActorRefFactory {


  /// Spawns (starts) TODO: wording I would suggest sticking to spawn since it is common vocabulary from erlang/akka and also "spawn a thread"
  /// a new Actor with the given initial behavior and name.
  public func spawn<Message>(_ behavior: Behavior<Message>, named name: String, props: Props = Props()) -> ActorRef<Message> {
    return FIXME("implement this")
  }

  // Implementation note:
  // It is important to have the anonymous one have a "long discouraging name", we want actors to be well named,
  // and devs should only opt into anonymous ones when they are aware that they do so and indeed that's what they want.
  // This is why there should not be default parameter values for actor names
  public func spawnAnonymous<Message>(_ behavior: Behavior<Message>, props: Props = Props()) -> ActorRef<Message> {
    return FIXME("implement this")
//         return spawn(behavior, named: self.anonymousNames.next(), props: props)
  }
}
