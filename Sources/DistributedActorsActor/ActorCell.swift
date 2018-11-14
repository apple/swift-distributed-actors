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

import NIO
import Dispatch

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// It must ONLY EVER be accessed from its own Actor.
/// It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).

public class ActorContext<Message> {

  // TODO in the subclass we need to apply some workarounds around `cannot override with a stored property 'myself'` since I want those to be vars
  // See: https://stackoverflow.com/questions/46676992/overriding-computed-property-with-stored-one

  /// Complete path in hierarchy of this Actor.
  /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
  ///
  /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
  /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO wording must match the semantics we decide on for supervision
  ///
  /// // TODO maybe we can pull of some better things with source location where one was started as well being carried here?
  /// // This would be for "debugging mode", not for log statements though; interesting idea tho; may want to be configurable since adds weight
  public var path: ActorPath {
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


  /// Watches the given actor for termination events, and will receive an `Terminated` signal
  /// when the watched actor is stopped.
  ///
  /// Death Pact: By watching an actor one enters signs a "death pact" with the watchee,
  /// meaning that it will also terminate itself once it receives the `Terminated(who)` signal
  /// about the watchee.
  ///
  /// Alternatively, one can handle the `Terminated` signal using the `.receiveSignal()` method,
  /// which gives this actor the ability to react to the watchee's death (e.g. by saying some nice words about its life time,
  /// or spawning a replacement worker in its' place).
  /// When the `Terminated` signal is handled by this actor, the automatic death pact will not be triggered.
  public func watch<M>(_ watchee: ActorRef<M>) {
    return undefined()
  }

  /// Reverts the watching of an previously watched actor.
  ///
  /// Unwatching a not-watched actor has no effect.
  public func unwatch<M>(_ watchee: ActorRef<M>) {
    return undefined()
  }

}

// MARK: Internal implementations, the so-called "cell"

// Implementation notes:
// The "cell" is where the "actual actor" is kept; it is also what handles all the invocations, restarts of that actor.
// Other classes in this file are all "internal" in the sense of implementation; yet are of course exposed to users
//
// The cell is mutable, as it may replace the behavior it hosts
public class ActorCell<Message>: ActorContext<Message> { // by the cell being the context we aim save space (does it save space in swift? in JVM it would)

  // TODO impl note: we need to ref hold the cell somehow, but the handed our refs dont have to, since they should go to deadletters once we terminate

  // Implementation notes:
  // The phrase that "actor change their behavior" is taken quite literally by our infrastructure,
  // on each message being applied the actor may return a new behavior that will be handling the next message.
  public var behavior: Behavior<Message>

  // Implementation of DeathWatch
  private var deathWatch: DeathWatch<Message>!

  private let _dispatcher: MessageDispatcher

  /// Guaranteed to be set during ActorRef creation
  /// Must never be exposed to users, rather expose the `ActorRef<Message>` by calling [[myself]].
  @usableFromInline internal var _myselfInACell: ActorRefWithCell<Message>?

  init(behavior: Behavior<Message>, dispatcher: MessageDispatcher) {
    // TODO we may end up referring to the system here... we'll see
    self.behavior = behavior
    self._dispatcher = dispatcher
    self.deathWatch = DeathWatch()
  }

  /// INTERNAL API: MUST be called immediately after constructing the cell and ref,
  /// as the actor needs to access its ref from its context during setup or other behavior reductions
  internal func set(ref: ActorRefWithCell<Message>) {
    self._myselfInACell = ref // TODO atomic?
  }

  @inlinable
  var context: ActorContext<Message> {
    return self
  }

  // MARK: Conforming to ActorContext

  override public var myself: ActorRef<Message> { return _myselfInACell! }

  override public var path: ActorPath { return self.myself.path }
  override public var name: String { return path.name }

  // access only from within actor
  private lazy var _log = ActorLogger(self.context)
  override public var log: Logger { return _log }

  override public var dispatcher: MessageDispatcher { return self._dispatcher }
  // MARK: Handling messages

  /// Interprets the incoming message using the current `Behavior` and swaps it with the
  /// next behavior (as returned by user code, which the message was applied to).
  ///
  /// WARNING: Mutates the cell's behavior.
  // FIXME @inlinable https://github.com/apple/swift-distributed-actors/issues/69
  func interpretMessage(message: Message) -> Bool {
    func interpretMessage0(_ behavior: Behavior<Message>, _ message: Message) -> Behavior<Message> {
      pprint("interpret: \(behavior), with message: \(message)")
        
      switch behavior {
      case let .receiveMessage(recv):       return recv(message)
      case let .receive(recv):              return recv(context, message)
      case .ignore:                         return .same // ignore message and remain .same
      case let .custom(behavior):           return behavior.receive(context: context, message: message)
      case let .signalHandling(recvMsg, _): return interpretMessage0(recvMsg, message) // TODO should we keep the signal handler even if not .same? // TODO more signal handling tests
      default:                              return TODO("NOT IMPLEMENTED YET: handling of: \(self.behavior)")
      }
    }

    let currentBehavior = self.behavior
    let next: Behavior<Message> = interpretMessage0(currentBehavior, message)
    log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)") // TODO make the \next printout nice TODO dont log messages (could leak pass etc)

    self.behavior = currentBehavior.canonicalize(context, next: next)
    self.becomeNext(behavior: next)
    return self.behavior.isStopped()
  }

  // MARK: Handling system messages

  /// Process single system message and return if processing of further shall continue.
  /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
  func interpretSystemMessage(message: SystemMessage) -> Bool {
    //    log.info("Interpret system message: \(message)")
    switch message {
    // initialization:
    case .start:
      self.interpretSystemStart()

    // death watch
    case let .watch(watcher):
      // TODO make DeathWatch methods available via extension
      self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself)

    case let .unwatch(watcher):
      // TODO make DeathWatch methods available via extension
      self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself)

    case let .terminated(ref, _):
      log.info("Received .terminated(\(ref.path))")
      self.deathWatch.receiveTerminated(message) // FIXME implement the logic well in there
      if case let .signalHandling(handleMsg, handleSignal) = self.behavior {
        let next = handleSignal(context, message) // TODO we want to deliver Signals to users
        becomeNext(behavior: next) // FIXME make sure we don't drop the behavior...?
      }

    case .terminate:
      // TODO SACT_CELL_DEBUG flag
      // the reason we only "really terminate" once we got the .terminated that during a run we set terminating
      // mailbox status, but obtaining the mailbox status and getting the
      // TODO reconsider this again and again ;-) let's do this style first though, it is the "safe bet"
      pprint("Terminating \(self.myself). Remaining messages will be drained to deadLetters.") 
      return self.finishTerminating()

    default:
      return TODO("invokeSystemMessage, handling of \(message) is not implemented yet; Behavior was: \(behavior)")
    }

    return self.behavior.isStillAlive()
  }

  /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
  /// Always invoke [[becomeNext]] rather than assigning to `self.behavior` manually.
  // TODO @inlinable but https://github.com/apple/swift-distributed-actors/issues/69
  internal func becomeNext(behavior next: Behavior<Message>) {
    // TODO handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too
    self.behavior = self.behavior.canonicalize(context, next: next)
    let alreadyDead: Bool = self.behavior.isStopped()
    if alreadyDead { self._myselfInACell?.sendSystemMessage(.terminate) }
  }

  // TODO @inlinable but https://github.com/apple/swift-distributed-actors/issues/69
  internal func interpretSystemStart() {
    // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly
    if case .setup(let onStart) = behavior {
      let next = onStart(context)
      self.becomeNext(behavior: next)
    } // else we ignore the .start, since no behavior is interested in it
    // and canonicalize() will make sure that any nested `.setup` are handled immediately as well
  }

  // MARK: Lifecycle and DeathWatch TODO move death watch things all into an extension

  // TODO this is also part of lifecycle / supervision... maybe should be in an extension for those

  /// One of the final methods to invoke when terminating->terminated
  func finishTerminating() -> Bool {
    let b = self.behavior
    // TODO: stop all children? depends which style we'll end up with...
    // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell
    self.notifyWatchersWeDied()
    // TODO: we could notify parent that we died... though I'm not sure we need to in the supervision style we'll do...

    // "nil out everything"
    self.deathWatch = nil
    self._myselfInACell = nil // TODO or a dead placeholder

    // TODO if SACT_DEBUG_CELL_LIFECYCLE
    pprint("\(b) TERMINATED.")
    // TODO endif SACT_DEBUG_CELL_LIFECYCLE

    return false
  }

  // Implementation note: bridge method so Mailbox can call this when needed
  // TODO not sure about this design yet
  func notifyWatchersWeDied() {
    self.deathWatch.notifyWatchersWeDied(myself: self.myself)
  }


  // MARK: External ActorContext API

  override public func watch<M>(_ watchee: ActorRef<M>) {
    self.deathWatch.watch(watchee: watchee, myself: context.myself)
  }

  override public func unwatch<M>(_ watchee: ActorRef<M>) {
    self.deathWatch.unwatch(watchee: watchee)
  }


}

extension ActorCell: CustomStringConvertible {
  public var description: String {
    return "\(type(of: self))(\(self.path))"
  }
}

