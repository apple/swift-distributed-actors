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

@usableFromInline let SACT_TRACE_CELL = false

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// Warning:
/// - It MOST only ever be accessed from its own Actor. It is fine though to close over it in the actors behaviours.
/// - It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).
public class ActorContext<Message> {

    // TODO: in the subclass we need to apply some workarounds around `cannot override with a stored property 'myself'` since I want those to be vars
    // See: https://stackoverflow.com/questions/46676992/overriding-computed-property-with-stored-one

    /// Complete path in hierarchy of this Actor.
    /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
    ///
    /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
    /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO: wording must match the semantics we decide on for supervision
    ///
    /// // TODO: maybe we can pull of some better things with source location where one was started as well being carried here?
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
    public var name: String { // TODO: decide if Substring or String; TBH we may go with something like ActorPathSegment and ActorPath?
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


    /// Watches the given actor for termination, which means that this actor will receive a `.terminated` signal
    /// when the watched actor is terminates ("dies").
    ///
    /// Death Pact: By watching an actor one enters a so-called "death pact" with the watchee,
    /// meaning that this actor will also terminate itself once it receives the `.terminated` signal
    /// for the watchee. A simple mnemonic to remember this is to think of the Romeo & Juliet scene where
    /// the lovers each kill themselves, thinking the other has died.
    ///
    /// Alternatively, one can handle the `.terminated` signal using the `.receiveSignal(Signal -> Behavior<Message>)` method,
    /// which gives this actor the ability to react to the watchee's death in some other fashion,
    /// for example by saying some nice words about its life, or spawning a "replacement" of watchee in its' place.
    ///
    /// When the `.terminated` signal is handled by this actor, the automatic death pact will not be triggered.
    /// If the `.terminated` signal is handled by returning `.unhandled` it is the same as if the signal was not handled at all,
    /// and the Death Pact will trigger as usual.
    public func watch<M>(_ watchee: ActorRef<M>) {
        return undefined()
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
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

    // TODO: impl note: we need to ref hold the cell somehow, but the handed our refs dont have to, since they should go to deadletters once we terminate

    // Implementation notes:
    // The phrase that "actor change their behavior" is taken quite literally by our infrastructure,
    // on each message being applied the actor may return a new behavior that will be handling the next message.
    public var behavior: Behavior<Message>

    internal var system: ActorSystem

    // Implementation of DeathWatch
    @usableFromInline internal var deathWatch: DeathWatch<Message>!

    private let _dispatcher: MessageDispatcher

    /// Guaranteed to be set during ActorRef creation
    /// Must never be exposed to users, rather expose the `ActorRef<Message>` by calling [[myself]].
    @usableFromInline internal var _myselfInACell: ActorRefWithCell<Message>?
    @usableFromInline internal var _myselfReceivesSystemMessages: ReceivesSystemMessages? {
        // This is a workaround for https://github.com/apple/swift-distributed-actors/issues/69
        return self._myselfInACell
    }

    init(behavior: Behavior<Message>, system: ActorSystem, dispatcher: MessageDispatcher) {
        // TODO: we may end up referring to the system here... we'll see
        self.behavior = behavior
        self._dispatcher = dispatcher
        self.system = system
        self.deathWatch = DeathWatch()
    }

    /// INTERNAL API: MUST be called immediately after constructing the cell and ref,
    /// as the actor needs to access its ref from its context during setup or other behavior reductions
    internal func set(ref: ActorRefWithCell<Message>) {
        self._myselfInACell = ref // TODO: atomic?
    }

    @inlinable
    var context: ActorContext<Message> {
        return self
    }

    // MARK: Dead letters

    // TODO make it a real actor ref with special casing (it is always dead)
    func drainToDeadLetters(_ message: Message) {
        print("[deadLetters] Message [\(message)]:\(type(of: message)) was not delivered. Dead letter encountered.")
        // system.deadLetters.tell(DeadLetter(message: message)) // TODO metadata
    }
    
    // MARK: Conforming to ActorContext

    /// Returns this actors "self" actor reference, which can be freely shared across
    /// threads, actors, and even nodes (if clustering is used).
    ///
    /// Warning: Do not use after actor has terminated (!)
    override public var myself: ActorRef<Message> {
        return _myselfInACell!
    }

    override public var path: ActorPath {
        return self.myself.path
    }
    override public var name: String {
        return path.name
    }

    // access only from within actor
    private lazy var _log = ActorLogger(self.context)
    override public var log: Logger {
        return _log
    }

    override public var dispatcher: MessageDispatcher {
        return self._dispatcher
    }

    // MARK: Handling messages

    /// Interprets the incoming message using the current `Behavior` and swaps it with the
    /// next behavior (as returned by user code, which the message was applied to).
    ///
    /// WARNING: Mutates the cell's behavior.
    @inlinable
    func interpretMessage(message: Message) -> Bool {
        if SACT_TRACE_CELL {
            pprint("interpret: [\(message)][:\(type(of: message))] with: \(behavior)")
        }
        let next = self.behavior.interpretMessage(context: context, message: message)
        if SACT_TRACE_CELL {
            log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
        } // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

        self.becomeNext(behavior: next)
        return self.behavior.isStopped()
    }

    // MARK: Handling system messages

    /// Process single system message and return if processing of further shall continue.
    /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
    ///
    /// Throws:
    ///   - user behavior thrown exceptions
    ///   - or `DeathPactError` when a watched actor terminated and the termination signal was not handled; See "death watch" for details.
    func interpretSystemMessage(message: SystemMessage) throws -> Bool {
        pprint("Interpret system message: \(message)")
        switch message {
            // initialization:
        case .start:
            self.interpretSystemStart()

            // death watch
        case let .watch(watcher):
            self.interpretSystemWatch(watcher: watcher)

        case let .unwatch(watcher):
            self.interpretSystemUnwatch(watcher: watcher)

        case let .terminated(ref):
            try self.interpretSystemTerminated(who: ref, message: message)

        case .tombstone:
            // the reason we only "really terminate" once we got the .terminated that during a run we set terminating
            // mailbox status, but obtaining the mailbox status and getting the
            // TODO: reconsider this again and again ;-) let's do this style first though, it is the "safe bet"
            pprint("\(self.myself) Received tombstone for. Remaining messages will be drained to deadLetters.")
            self.finishTerminating()
            return false
        }

        return self.behavior.isStillAlive()
    }

    @inlinable internal func interpretSystemWatch(watcher: AnyReceivesSystemMessages) {
        switch self.behavior {
        case .stopped:
            // so we are in the middle of terminating already anyway
            watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself)))
        default:
            // TODO: make DeathWatch methods available via extension
            self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself)
        }
    }

    @inlinable internal func interpretSystemUnwatch(watcher: AnyReceivesSystemMessages) {
        self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself) // TODO: make DeathWatch methods available via extension
    }

    /// Interpret incoming .terminated system message
    ///
    /// Mutates actor cell behavior.
    /// May cause actor to terminate upon error or returning .stopped etc from `.signalHandling` user code.
    @inlinable internal func interpretSystemTerminated(who ref: AnyAddressableActorRef, message: SystemMessage) throws {
        if SACT_TRACE_CELL {
            log.info("Received .terminated(\(ref.path))")
        }
        guard self.deathWatch.receiveTerminated(message) else {
            // it is not an actor we currently watch, thus we should not take actions nor deliver the signal to the user
            log.warn("Actor not known yet \(message) received for it.")
            return
        }
        self.deathWatch.receiveTerminated(message)

        let next: Behavior<Message>
        if case let .signalHandling(_, handleSignal) = self.behavior {
            next = handleSignal(context, message) // TODO: we want to deliver Signals to users
        } else {
            // no signal handling installed is semantically equivalent to unhandled
            // log.debug("No .signalHandling installed, yet \(message) arrived; Assuming .unhandled")
            next = Behavior<Message>.unhandled
        }

        switch next {
        case .unhandled: throw DeathPactError.unhandledDeathPact(terminated: ref, myself: context.myself,
            message: "Death pact error: [\(context.myself)] has not handled termination received from watched watched [\(ref.path)] actor. " +
                "Handle the `.terminated` signal in `.receiveSignal()` in order react to this situation differently than termination.")
        default: becomeNext(behavior: next) // FIXME make sure we don't drop the behavior...?
        }
    }

    /// Fails the actor using the passed in error.
    ///
    /// May ONLY be invoked by the Mailbox.
    ///
    /// TODO: any kind of supervision things.
    ///
    /// Special handling is applied to [[DeathPactError]] since if that error is passed in here, we know that `.terminated`
    /// was not handled and we have to adhere to the DeathPact contract by stopping this actor as well.
    // TODO: not sure if this should mutate the cell or return to mailbox the nex behavior
    internal func fail(error: Error) {
        // TODO: we could handle here "wait for children to terminate"

        // we only finishTerminating() here and not right away in message handling in order to give the Mailbox
        // a chance to react to the problem as well; I.e. 1) we throw 2) mailbox sets terminating 3) we get fail() 4) we REALLY terminate
        switch error {
        case is DeathPactError:
            log.error("Actor failing, death pact: \(error)")
            self.finishTerminating() // FIXME likely too eagerly

        default:
            log.error("Actor failing, reason: \(error)")
            self.finishTerminating() // FIXME likely too eagerly
        }
    }

    /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
    /// Always invoke [[becomeNext]] rather than assigning to `self.behavior` manually.
    ///
    /// Returns: `true` if next behavior is .stopped and appropriate actions will be taken
    @inlinable
    internal func becomeNext(behavior next: Behavior<Message>) {
        // TODO: handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too

        self.behavior = self.behavior.canonicalize(context, next: next)

        // FIXME: this was wrong, the MUST ONLY BE ISSUED ONCE TERMINATING and the mailbox is closed otherwise another message can race and still make it into the mailbox
//        let alreadyDead: Bool = self.behavior.isStopped()
//        if alreadyDead {
//            self._myselfReceivesSystemMessages!.sendSystemMessage(.tombstone)
//        }
    }

    @inlinable
    internal func interpretSystemStart() {
        // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly
        if case .setup(let onStart) = behavior {
            let next = onStart(context)
            self.becomeNext(behavior: next) // for system messages we check separately if we should trigger stopping
        } else {
            self.becomeNext(behavior: .same)
        }
        // and canonicalize() will make sure that any nested `.setup` are handled immediately as well
    }

    // MARK: Lifecycle and DeathWatch TODO move death watch things all into an extension

    // TODO: this is also part of lifecycle / supervision... maybe should be in an extension for those

    /// One of the final methods to invoke when terminating->terminated
    ///
    /// Always causes behavior to become `.stopped`.
    internal func finishTerminating() {
        self._myselfInACell?.mailbox.setClosed()

        let myPath: ActorPath? = self._myselfInACell?.path
        pprint("FINISH TERMINATING \(myPath)")

        let b = self.behavior
        // TODO: stop all children? depends which style we'll end up with...
        // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell
        self.notifyWatchersWeDied()
        // TODO: we could notify parent that we died... though I'm not sure we need to in the supervision style we'll do...

        // TODO validate all the nulling out; can we null out the cell itself?
        // "nil out everything"
        self.deathWatch = nil
        self.behavior = .stopped
//        self._myselfInACell = nil

        pprint("CLOSED DEAD: \(myPath)")
    }

    // Implementation note: bridge method so Mailbox can call this when needed
    // TODO: not sure about this design yet
    func notifyWatchersWeDied() {
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }


    // MARK: External ActorContext API

    override public func watch<M>(_ watchee: ActorRef<M>) {
        self.deathWatch.watch(watchee: watchee.internal_boxAnyReceivesSignals().internal_exposeBox(), myself: context.myself)
    }

    override public func unwatch<M>(_ watchee: ActorRef<M>) {
        self.deathWatch.unwatch(watchee: watchee.internal_boxAnyReceivesSignals().internal_exposeBox(), myself: context.myself)
    }


}

extension ActorCell: CustomStringConvertible {
    public var description: String {
        let path = self._myselfInACell?.path.description ?? "<terminated-TODO>" // FIXME path should always remain safe to touch, also after termination (!)
        return "\(type(of: self))(\(path))"
    }
}

