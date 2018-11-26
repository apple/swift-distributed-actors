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

    internal init(behavior: Behavior<Message>, dispatcher: MessageDispatcher) {
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

    // MARK: ActorCellSpawning protocol requirements

    internal var children: Children = Children()
    func sendToDeadLetters(_ letter: DeadLetter) {
        system.deadLetters.tell(letter) // TODO metadata
    }

    func dropMessage(_ message: Message) {
        // TODO implement support for logging dropped messages; those are different than deadLetters
        pprint("[dropped] Message [\(message)]:\(type(of: message)) was not delivered.")
        // system.deadLetters.tell(DeadLetter(message)) // TODO metadata
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
    /// Warning: Mutates the cell's behavior.
    /// Returns: `true` if the actor remains alive, and `false` if it now is becoming `.stopped`
    @inlinable
    func interpretMessage(message: Message) -> Bool {
        #if SACT_TRACE_CELL
        pprint("interpret: [\(message)][:\(type(of: message))] with: \(behavior)")
        #endif
        let next = self.behavior.interpretMessage(context: context, message: message)
        #if SACT_TRACE_CELL
        log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
        #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

        self.becomeNext(behavior: next)
        return self.behavior.isStillAlive()
    }

    // MARK: Handling system messages

    /// Process single system message and return if processing of further shall continue.
    /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
    ///
    /// Throws:
    ///   - user behavior thrown exceptions
    ///   - or `DeathPactError` when a watched actor terminated and the termination signal was not handled; See "death watch" for details.
    func interpretSystemMessage(message: SystemMessage) throws -> Bool {
        traceLog_Cell("Interpret system message: \(message)")

        switch message {
            // initialization:
        case .start:
            self.interpretSystemStart()

            // death watch
        case let .watch(_, watcher):
            self.interpretSystemWatch(watcher: watcher)

        case let .unwatch(_, watcher):
            self.interpretSystemUnwatch(watcher: watcher)

        case let .terminated(ref, _):
            try self.interpretSystemTerminated(who: ref, message: message)

        case .tombstone:
            // the reason we only "really terminate" once we got the .terminated that during a run we set terminating
            // mailbox status, but obtaining the mailbox status and getting the
            // TODO: reconsider this again and again ;-) let's do this style first though, it is the "safe bet"
            traceLog_Cell("\(self.myself) Received tombstone. Remaining messages will be drained to deadLetters.")
            self.finishTerminating()
            return false
        }

        return self.behavior.isStillAlive()
    }

    @inlinable internal func interpretSystemWatch(watcher: AnyReceivesSystemMessages) {
        switch self.behavior {
        case .stopped:
            // so we are in the middle of terminating already anyway
            watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself), existenceConfirmed: true))
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
        #if SACT_TRACE_CELL
        log.info("Received .terminated(\(ref.path))")
        #endif
        guard self.deathWatch.receiveTerminated(message) else {
            // it is not an actor we currently watch, thus we should not take actions nor deliver the signal to the user
            log.warn("Actor not known yet \(message) received for it.")
            return
        }

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
            message: "Death Pact error: [\(context.myself)] has not handled .terminated signal received from watched [\(ref)] actor. " +
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
        case let DeathPactError.unhandledDeathPact(_, _, message):
            log.error("\(message)")
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

    /// This is the final method a Cell ever runs.
    /// It notifies any remaining watchers about its termination, releases any remaining resources,
    /// and clears its behavior, allowing state kept inside it to be released as well.
    ///
    /// Once this method returns the cell becomes "terminated", an empty shell, and may never be run again.
    /// This is coordinated with its mailbox, which by then becomes closed, and shall no more accept any messages, not even system ones.
    ///
    /// Any remaining system messages are to be drained to deadLetters by the mailbox in its current run.
    ///
    // ./' It all comes, tumbling down, tumbling down, tumbling down... ./'
    internal func finishTerminating() {
        self._myselfInACell?.mailbox.setClosed()

        let myPath: ActorPath? = self._myselfInACell?.path
        traceLog_Cell("FINISH TERMINATING \(String(describing: myPath))")

        // TODO: stop all children? depends which style we'll end up with...
        // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell
        self.notifyWatchersWeDied()
        // TODO: we could notify parent that we died... though I'm not sure we need to in the supervision style we'll do...

        // TODO validate all the nulling out; can we null out the cell itself?
        self.deathWatch = nil
        self._myselfInACell = nil
        self.behavior = .stopped

        traceLog_Cell("CLOSED DEAD: \(String(describing: myPath))")
    }

    // Implementation note: bridge method so Mailbox can call this when needed
    // TODO: not sure about this design yet
    func notifyWatchersWeDied() {
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }

    // MARK: Spawn

    public override func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        return try self.internal_spawn(behavior, name: name, props: props)
    }

    // MARK: Death Watch

    override public func watch<M>(_ watchee: ActorRef<M>) {
        self.deathWatch.watch(watchee: watchee.internal_boxAnyReceivesSignals(), myself: context.myself)
    }

    override public func unwatch<M>(_ watchee: ActorRef<M>) {
        self.deathWatch.unwatch(watchee: watchee.internal_boxAnyReceivesSignals(), myself: context.myself)
    }
}

extension ActorCell: CustomStringConvertible {
    public var description: String {
        let path = self._myselfInACell?.path.description ?? "<terminated-TODO>" // FIXME path should always remain safe to touch, also after termination (!)
        return "\(type(of: self))(\(path))"
    }
}


protocol ChildActorRefFactory: ActorRefFactory {
    // MARK: Interface with actor cell

    var children: Children { get set }

    // MARK: Additional

    func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props) throws -> ActorRef<Message>
    func stop<M>(child ref: ActorRef<M>) throws

}

/// Represents all the (current) children this actor has spawned.
///
/// Convenience methods for locating children are provided, although it is recommended to keep the [[ActorRef]]
/// of spawned actors in the context of where they are used, rather than looking them up continiously.
public struct Children {

    typealias Name = String
    private var container: [Name: BoxedHashableAnyReceivesSignals]

    public init() {
        self.container = [:]
    }

    public func find<T>(named name: String, withType: T.Type) -> ActorRef<T>? {
        guard let boxedChild = container[name] else {
            return nil
        }

        return boxedChild.internal_exposeAs(ActorRef<T>.self)
    }
    
    public mutating func insert<T, R: ActorRef<T>>(_ childRef: R) {
        container[childRef.path.name] = childRef.internal_boxAnyReceivesSignals()
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    /// Returns: `true` upon successful removal and the the passed in ref was indeed a child of this actor, false otherwise
    internal mutating func remove<T, R: ActorRef<T>>(_ childRef: R) -> Bool {
        let removed = container.removeValue(forKey: childRef.path.name)
        return removed != nil
    }

}

// TODO: Trying this style rather than the style done with DeathWatch to extend cell's capabilities
extension ActorCell: ChildActorRefFactory {

    // TODO: Very similar to top level one, though it will be differing in small bits... Likely not worth to DRY completely
    internal func internal_spawn<Message2>(_ behavior: Behavior<Message2>, name: String, props: Props) throws -> ActorRef<Message2> {
        try behavior.validateAsInitial()
        // TODO prefix $ validation (only ok for anonymous)

        let nameSegment = try ActorPathSegment(name)
        let path = self.path / nameSegment
        // TODO reserve name

        let d = dispatcher // TODO this is dispatcher inheritance, we dont want that
        let cell: ActorCell<Message2> = ActorCell<Message2>(behavior: behavior, dispatcher: d)
        let mailbox = Mailbox(cell: cell, capacity: props.mailbox.capacity)

        log.info("Spawning [\(behavior)], child of [\(self.path)], full path: [\(path)]")

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)


        self.children.insert(refWithCell)

        return refWithCell
    }

    internal func internal_stop<T>(child ref: ActorRef<T>) throws {
        // we immediately attempt the remove since
        guard self.children.remove(ref) else {
            throw ActorError.attemptedStoppingNonChildActor(ref: ref)
        }

        // TODO this is not really correct, just placeholder code for now
        ref.internal_downcast.sendSystemMessage(.tombstone)
    }
}


public enum ActorError: Error {
    case attemptedStoppingNonChildActor(ref: AnyAddressableActorRef)
}
