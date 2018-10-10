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
//
// The cell is mutable, as it may replace the behavior it hosts
public class ActorCell<Message>: ActorContext<Message> { // by the cell being the context we aim save space (does it save space in swift? in JVM it would)

  // keep the behavior, context, dispatcher references etc

  // Implementation notes:
  // The phrase that "actor change their behavior" is taken quite literally by our infrastructure,
  // on each message being applied the actor may return a new behavior that will be handling the next message.
  private var behavior: Behavior<Message>

  internal let _dispatcher: MessageDispatcher

  /// Guaranteed to be set during ActorRef creation
  private var _myself: ActorRef<Message>?

  init(behavior: Behavior<Message>, dispatcher: MessageDispatcher) {
    // TODO we may end up referring to the system here... we'll see
    self.behavior = behavior
    self._dispatcher = dispatcher
  }

  /// INTERNAL API: MUST be called immediately after constructing the cell and ref,
  /// as the actor needs to access its ref from its context during setup or other behavior reductions
  public func set(ref: ActorRef<Message>) {
    self._myself = ref // TODO atomic?
  }

  @inlinable
  var context: ActorContext<Message> {
    return self
  }

  // MARK: Conforming to ActorContext

  override public var myself: ActorRef<Message> { return _myself! }

  // FIXME move to proper actor paths
  override public var path: String { return super.path }
  override public var name: String { return String(self.path.split(separator: "/").last!) }

  // access only from within actor
  private lazy var _log = ActorLogger(self.context)
  override public var log: Logger { return _log }
  
  override public var dispatcher: MessageDispatcher { return self._dispatcher }
  // MARK: Handling messages


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

  func invokeSystem(message: SystemMessage) {
    switch behavior {
    case let .setup(setupFunction):
      let next: Behavior<Message> = setupFunction(context)
      self.behavior = next

    default:
      // ...
      print("invokeSystem, unknown behavior: \(behavior)")
      return FIXME("Actually run the actors behavior")
    }
  }
}

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// It must ONLY EVER be accessed from its own Actor.
/// It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).

public class ActorContext<Message> {

  // TODO in the sublass we need to apply some workarounds around `cannot override with a stored property 'myself'` since I want those to be vars
  // See: https://stackoverflow.com/questions/46676992/overriding-computed-property-with-stored-one

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
  public var path: String { // TODO ActorPath to abstract over it and somehow optimize it?
    return undefined()
  }

  /// Name of the Actor
  /// The `name` is the last segment of the Actor's `path`
  ///
  /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
  // Implementation note:
  // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
  // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
  public var name: String { // TODO decide if Substring or String; TBH we may go with something like ActorPathSegment and ActorPath?
    return undefined()
  }

  /// The actor reference to _this_ actor.
  ///
  /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
  /// as such would not be the "same" actor anymore.
  // Implementation note:
  // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
  // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
  // to get developers into the right mindset.
  public var myself: ActorRef<Message> {
    return undefined()
  }


  /// Provides context metadata aware logger
  // TODO: API wise this logger will be whichever type the SSWG group decides on, we will adopt it
  public var log: Logger {
    return undefined()
  }

  public var dispatcher: MessageDispatcher {
    return undefined()
  }

}