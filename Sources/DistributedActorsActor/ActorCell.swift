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

// Implementation notes:
// The "cell" is where the "actual actor" is kept; it is also what handles all the invocations, restarts of that actor.
// Other classes in this file are all "internal" in the sense of implementation; yet are of course exposed to users

public protocol AnyActorCell {

}

// pretty sure it has to be a class; it will do all the horrible mutating things :-)
internal class ActorCell<Message>: AnyActorCell {
  // keep the behavior, context, dispatcher references etc

  // Implementation notes:
  // The phrase that "actor change their behavior" is taken quite literally by our infrastructure,
  // on each message being applied the actor may return a new behavior that will be handling the next message.
  private var behavior: Behavior<Message>

  internal let dispatcher: MessageDispatcher

  init(behavior: Behavior<Message>, dispatcher: MessageDispatcher) {
    // TODO we may end up referring to the system here... we'll see
    self.behavior = behavior
    self.dispatcher = dispatcher
  }

//  var context: ActorContext<Message> {
//    return self // TODO make this real
//  }

  func start() {
    // TODO "now actually ready to process messages"
  }

  // TODO should this mutate the cel itself?
  func invokeMessage(message: Message) -> Behavior<Message> {
    switch self.behavior {
    case let .receive(recv):
      return recv(message)
    default:
      return TODO("NOT IMPLEMENTED YET: handling of: \(self.behavior)")
    }
  }

  func nextBehavior(_ next: Behavior<Message>) {
    // TODO canonicalize (remove not needed layers etc)
    self.behavior = next
  }

  func invokeSystemMessage(sysMessage: SystemMessage) {
    return FIXME("Actually run the actors behavior")
  }
}

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// It must ONLY EVER be accessed from its own Actor.
/// It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).

// TODO in Akka to save space AFAIR we made the context IS-A with the cell; which means we need it to be a class anyway...
public struct ActorContext<Message> {

  /// Complete path in hierarchy of this Actor.
  /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
  ///
  /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
  /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO wording must match the semantics we decide on for supervision
  ///
  /// // TODO maybe we can pull of some better things with source location where one was started as well being carried here?
  /// // This would be for "debugging mode", not for log statements though; interesting idea tho; may want to be configurable since adds weight
  ///
  /// Invariants: MUST NOT be empty.
  public let path: String // TODO ActorPath to abstract over it and somehow optimize it?

  /// Name of the Actor
  /// The `name` is the last segment of the Actor's `path`
  ///
  /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
  // Implementation note:
  // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
  // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
  public let name: String // TODO decide if Substring or String; TBH we may go with something like ActorPathSegment and ActorPath?

  /// The actor reference to _this_ actor.
  ///
  /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
  /// as such would not be the "same" actor anymore.
  // Implementation note:
  // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
  // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
  // to get developers into the right mindset.
  public let myself: ActorRef<Message>

  init(path: String, yourself myself: ActorRef<Message>) { // I've not watched the series, but the pun was asking for it...
    self.path = path
    self.name = String(path.split(separator: "/").last!) // FIXME should we keep it as Substring? or is it a hassle for users?
    self.myself = myself
  }
}