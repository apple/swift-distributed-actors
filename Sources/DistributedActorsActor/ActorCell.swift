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
import CSwiftDistributedActorsMailbox

// MARK: Actor internals; The so-called "cell" contains the actual "actor"

// Implementation notes:
// The "cell" is where the "actual actor" is kept; it is also what handles all the invocations, restarts of that actor.
// Other classes in this file are all "internal" in the sense of implementation; yet are of course exposed to users
// A strong reference to `ActorCell` is stored in `Children`. This is the one reference that keeps the ActorCell alive
// until the actor is logically stopped. We only store weak references to `ActorCell` everywhere else. We have to do this
// to prevent `ActorCell`s from sticking around when users hold on to an `ActorRef` after the actor has been terminated.
//
// The cell is mutable, as it may replace the behavior it hosts
public class ActorCell<Message>: ActorContext<Message>, FailableActorCell, AbstractCell {
    // TODO: the cell IS-A context is how we saved space on the JVM, though if context is a struct it does not matter here, perhaps reconsider

    // Each actor belongs to a specific Actor system, and may reach for it if it so desires:
    @usableFromInline internal var _system: ActorSystem
    public override var system: ActorSystem {
        return self._system
    }

    // MARK: The actors' "self" and relationships

    typealias SelfBehavior = Behavior<Message>

    // TODO: impl note: we need to ref hold the cell somehow, but the handed our refs dont have to, since they should go to deadletters once we terminate

    // Implementation notes:
    // The phrase that "actor change their behavior" is taken quite literally by our infrastructure,
    // on each message being applied the actor may return a new behavior that will be handling the next message.
    public var behavior: Behavior<Message>

    override public var timers: Timers<Message> {
        return self._timers
    }

    lazy var _timers: Timers<Message> = Timers(context: self)

    internal let _parent: AnyReceivesSystemMessages

    internal let _path: UniqueActorPath

    internal let _props: Props

    // MARK: Fault handling infrastructure

    // We always have a supervisor in place, even if it is just the ".stop" one.
    @usableFromInline internal let supervisor: Supervisor<Message>
    // TODO: we can likely optimize not having to call "through" supervisor if we are .stopped anyway

    // MARK: Death watch infrastructure

    // Implementation of DeathWatch
    @usableFromInline internal var deathWatch: DeathWatch<Message>!

    private let _dispatcher: MessageDispatcher

    /// Guaranteed to be set during ActorRef creation
    /// Must never be exposed to users, rather expose the `ActorRef<Message>` by calling [[myself]].
    @usableFromInline internal lazy var _myselfInACell: ActorRefWithCell<Message> = ActorRefWithCell<Message>(
        path: self._path,
        cell: self,
        mailbox: Mailbox(cell: self, capacity: self._props.mailbox.capacity)
    )
    @usableFromInline internal var _myselfReceivesSystemMessages: ReceivesSystemMessages {
        // This is a workaround for https://github.com/apple/swift-distributed-actors/issues/69
        return self._myselfInACell
    }

    // MARK: ActorCell implementation

    internal init(system: ActorSystem, parent: AnyReceivesSystemMessages,
                  behavior: Behavior<Message>, path: UniqueActorPath,
                  props: Props, dispatcher: MessageDispatcher) {
        self._system = system
        self._parent = parent

        self.behavior = behavior
        self._path = path
        self._props = props
        self._dispatcher = dispatcher

        self.supervisor = Supervision.supervisorFor(system, initialBehavior: behavior, props: props.supervision)

        self.deathWatch = DeathWatch()

        #if SACT_TESTS_LEAKS
        _ = system.cellInitCounter.add(1)
        #endif
    }

    deinit {
        traceLog_Cell("deinit cell \(_path)")
        #if SACT_TESTS_LEAKS
        _ = system.cellInitCounter.sub(1)
        #endif
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

    internal var _children: Children = Children()
    override public var children: Children {
        set {
            self._children = newValue
        }
        get {
            return self._children
        }
    }

    func sendToDeadLetters<M>(message: M) {
        system.deadLetters.tell(DeadLetter(message)) // TODO metadata
    }

    func dropMessage(_ message: Message) {
        // TODO implement support for logging dropped messages; those are different than deadLetters
        pprint("[dropped] Message [\(message)]:\(type(of: message)) was not delivered.")
        // system.deadLetters.tell(Dropped(message)) // TODO metadata
    }
    
    // MARK: Conforming to ActorContext

    /// Returns this actors "self" actor reference, which can be freely shared across
    /// threads, actors, and even nodes (if clustering is used).
    ///
    /// Warning: Do not use after actor has terminated (!)
    override public var myself: ActorRef<Message> {
        return self._myselfInACell
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var path: UniqueActorPath {
        return self._path
    }
    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var name: String {
        return self.path.name
    }

    // access only from within actor
    private lazy var _log = ActorLogger.make(context: self.context)
    override public var log: Logger {
        get {
            return self._log
        }
        set {
            self._log = newValue
        }
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
    func interpretMessage(message: Message) throws -> Bool {
        #if SACT_TRACE_CELL
        pprint("Interpret: [\(message)]:\(type(of: message)) with: \(behavior)")
        #endif

        // if a behavior was wrapped with supervision, this interpretMessage would encapsulate and contain the throw
        let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: message)

        #if SACT_TRACE_CELL
        log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
        #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

        try self.becomeNext(behavior: next)

        if !self.behavior.isStillAlive {
            children.forEach { $0.sendSystemMessage(.stop) }
        }

        return self.continueRunning
    }

    // MARK: Handling system messages

    /// Process single system message and return if processing of further shall continue.
    /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
    ///
    /// Throws:
    ///   - user behavior thrown exceptions
    ///   - or `DeathPactError` when a watched actor terminated and the termination signal was not handled; See "death watch" for details.
    /// Fails:
    ///   - can potentially fail, which is handled by [FaultHandling] and terminates an actor run immediately.
    func interpretSystemMessage(message: SystemMessage) throws -> Bool {
        traceLog_Cell("Interpret system message: \(message)")

        switch message {
        // initialization
        case .start:
            try self.interpretStart()

        // death watch
        case let .watch(_, watcher):
            self.interpretSystemWatch(watcher: watcher)
        case let .unwatch(_, watcher):
            self.interpretSystemUnwatch(watcher: watcher)

        case let .terminated(ref, existenceConfirmed):
            let terminated = Signals.Terminated(path: ref.path, existenceConfirmed: existenceConfirmed)
            try self.interpretTerminatedSignal(who: ref, terminated: terminated)
        case let .childTerminated(ref):
            let terminated = Signals.ChildTerminated(path: ref.path, error: nil) // TODO what about the errors
            try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)

        case .tombstone:
            // the reason we only "really terminate" once we got the .terminated that during a run we set terminating
            // mailbox status, but obtaining the mailbox status and getting the
            // TODO: reconsider this again and again ;-) let's do this style first though, it is the "safe bet"
            traceLog_Cell("\(self.myself) Received tombstone. Remaining messages will be drained to deadLetters.")
            self.finishTerminating()
            return false

        case .stop:
            children.forEach { $0.sendSystemMessage(.stop) }
            try self.becomeNext(behavior: .stopped)
        }

        return self.continueRunning
    }

    func interpretClosure(_ closure: () throws -> Void) throws -> Bool {
        let next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, closure: closure)

        #if SACT_TRACE_CELL
        log.info("Applied closure, becoming: \(next)")
        #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

        try self.becomeNext(behavior: next)

        if !self.behavior.isStillAlive {
            children.forEach { $0.sendSystemMessage(.stop) }
        }

        return self.continueRunning
    }

    @usableFromInline
    internal var continueRunning: Bool {
        return self.behavior.isStillAlive || self.children.nonEmpty
    }

    /// Fails the actor using the passed in error.
    ///
    /// May ONLY be invoked by the Mailbox.
    ///
    /// Special handling is applied to [[DeathPactError]] since if that error is passed in here, we know that `.terminated`
    /// was not handled and we have to adhere to the DeathPact contract by stopping this actor as well.
    ///
    /// We only FORCE the sending of a tombstone if we know we have parked the thread because an actual failure happened,
    /// thus this run *will never complete* and we have to make sure that we run the cleanup that the tombstone causes.
    /// This means that while the current thread is parked forever, we will enter the mailbox with another last run (!), to process the cleanups.
    internal func fail(error: Error) {
        self._myselfInACell.mailbox.setFailed()
        // TODO: we could handle here "wait for children to terminate"

        // we only finishTerminating() here and not right away in message handling in order to give the Mailbox
        // a chance to react to the problem as well; I.e. 1) we throw 2) mailbox sets terminating 3) we get fail() 4) we REALLY terminate
        switch error {
        case let DeathPactError.unhandledDeathPact(_, _, message):
            log.error("\(message)") // TODO configurable logging? in props?
            self.finishTerminating() // FIXME likely too eagerly

        default:
            log.error("Actor threw error, reason: [\(error)]:\(type(of: error))") // TODO configurable logging? in props?
            // sact_dump_backtrace() // shows mostly mailbox info, not so useful for users

            self.finishTerminating() // FIXME likely too eagerly
        }
    }

    /// Similar to `fail` however assumes that the current mailbox run will never complete, which can happen when we crashed,
    /// and invoke this function from a signal handler.
    // Implementation notes: Similar to `fail()` but trying to keep them separate as fail() can be called during a run
    // where we catch an exception thrown by user code and then the run continues and then we send the tombstone.
    public func crashFail(error: Error) {

        // if supervision or configurations or failure domain dictates something else will happen, explain it to the user here
        let crashHandlingExplanation = "Terminating actor, process and thread remain alive."

        log.error("Actor crashing, reason: [\(error)]:\(type(of: error)). \(crashHandlingExplanation)")

        self.finishTerminating() // FIXME likely too eagerly
    }

    /// Used by supervision, from failure recovery.
    /// In such case the cell must be restarted while the mailbox remain in-tact.
    @inlinable public func restart(behavior: Behavior<Message>) throws {
        // TODO likely don't log here...
        self.log.warning("Restarting.")

        self.timers.cancelAll()
        try _ = self.behavior.interpretSignal(context: self.context, signal: Signals.PreRestart())
        self.behavior = behavior
        try self.interpretStart()
    }

    /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
    /// Always invoke [[becomeNext]] rather than assigning to `self.behavior` manually.
    ///
    /// Returns: `true` if next behavior is .stopped and appropriate actions will be taken
    @inlinable
    internal func becomeNext(behavior next: Behavior<Message>) throws {
        // TODO: handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too

        self.behavior = try self.behavior.canonicalize(context, next: next)
    }

    @inlinable
    internal func interpretStart() throws {
        // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly

        traceLog_Cell("START with behavior: \(self.behavior)")
        let started = try self.behavior.start(context: self)
        try self.becomeNext(behavior: started)
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
        self._myselfInACell.mailbox.setClosed()

        let myPath: UniqueActorPath? = self._myselfInACell.path
        traceLog_Cell("FINISH TERMINATING \(self)")

        // TODO: stop all children? depends which style we'll end up with...
        // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell

        self.timers.cancelAll()

        // TODO avoid notifying parent two times (!)
        self.notifyWatchersWeDied()
        self.notifyParentWeDied()
        // TODO: we could notify parent that we died... though I'm not sure we need to in the supervision style we'll do...

        do {
            _ = try self.behavior.interpretSignal(context: self.context, signal: Signals.PostStop())
        } catch {
            // TODO: should probably .escalate instead
            self.context.log.error("Exception in postStop", error: error)
        }

        // TODO validate all the nulling out; can we null out the cell itself?
        self.deathWatch = nil
        self.behavior = .stopped // TODO or failed...

        traceLog_Cell("CLOSED DEAD: \(String(describing: myPath))")
    }

    // Implementation note: bridge method so Mailbox can call this when needed
    // TODO: not sure about this design yet
    func notifyWatchersWeDied() {
        traceLog_DeathWatch("NOTIFY WATCHERS WE ARE DEAD self: \(self.path)")
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }
    func notifyParentWeDied() {
        traceLog_DeathWatch("NOTIFY PARENT WE ARE DEAD self: \(self.path)")
        let parent: AnyReceivesSystemMessages = self._parent
        parent.sendSystemMessage(.childTerminated(ref: myself._boxAnyAddressableActorRef()))
    }

    // MARK: Spawn implementations

    public override func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        return try self.internal_spawn(behavior, name: name, props: props)
    }

    public override func spawnAnonymous<M>(_ behavior: Behavior<M>, props: Props = Props()) throws -> ActorRef<M> {
        return try self.internal_spawn(behavior, name: self.system.anonymousNames.nextName(), props: props)
    }

    public override func spawnWatched<M>(_ behavior: Behavior<M>, name: String, props: Props = Props()) throws -> ActorRef<M> {
        return self.watch(try self.spawn(behavior, name: name, props: props))
    }

    public override func stop<M>(child ref: ActorRef<M>) throws {
        return try self.internal_stop(child: ref)
    }

    // MARK: Death Watch

    override public func watch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.deathWatch.watch(watchee: watchee._boxAnyReceivesSystemMessages(), myself: context.myself)
        return watchee
    }

    override public func unwatch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        self.deathWatch.unwatch(watchee: watchee._boxAnyReceivesSystemMessages(), myself: context.myself)
        return watchee
    }
}

// MARK: Internal system message / signal handling functions

extension ActorCell {
    @inlinable internal func interpretSystemWatch(watcher: AnyReceivesSystemMessages) {
        if self.behavior.isStillAlive {
            // TODO: make DeathWatch methods available via extension
            self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself)
        } else {
            // so we are in the middle of terminating already anyway
            watcher.sendSystemMessage(.terminated(ref: self._myselfInACell._boxAnyAddressableActorRef(), existenceConfirmed: true))
        }
    }

    @inlinable internal func interpretSystemUnwatch(watcher: AnyReceivesSystemMessages) {
        self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself) // TODO: make DeathWatch methods available via extension
    }

    /// Interpret incoming .terminated system message
    ///
    /// Mutates actor cell behavior.
    /// May cause actor to terminate upon error or returning .stopped etc from `.signalHandling` user code.
    @inlinable internal func interpretTerminatedSignal(who deadRef: AnyAddressableActorRef, terminated: Signals.Terminated) throws {
        #if SACT_TRACE_CELL
        log.info("Received terminated: \(deadRef)")
        #endif

        guard self.deathWatch.receiveTerminated(terminated) else {
            // it is not an actor we currently watch, thus we should not take actions nor deliver the signal to the user
            log.warning("Actor not known yet [\(terminated)] received for it. Ignoring.")
            return
        }

        let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)

        switch next {
        case .unhandled:
            throw DeathPactError.unhandledDeathPact(terminated: deadRef, myself: context.myself,
                message: "Death Pact error: [\(context.path)] has not handled [Terminated] signal received from watched [\(deadRef)] actor. " +
                    "Handle the `.terminated` signal in `.receiveSignal()` in order react to this situation differently than termination.")
        default:
            try becomeNext(behavior: next) // FIXME make sure we don't drop the behavior...?
        }
    }

    @inlinable internal func interpretChildTerminatedSignal(who terminatedRef: AnyAddressableActorRef, terminated: Signals.ChildTerminated) throws {
        #if SACT_TRACE_CELL
        log.info("Received \(terminated)")
        #endif

        // we always first need to remove the now terminated child from our children
        _ = self.children.removeChild(identifiedBy: terminatedRef.path)
        // Implementation notes:
        // Normally this does not happen, however it MAY occur when the parent actor (self)
        // immediately performed a `stop()` on the child, and thus removes it from its
        // children container immediately; The following termination notification would therefore
        // reach the parent in which the child was already removed.

        // next we may apply normal deathWatch logic if the child was being watched
        if self.deathWatch.isWatching(path: terminatedRef.path) {
            return try self.interpretTerminatedSignal(who: terminatedRef, terminated: terminated)
        } else {
            // otherwise we deliver the message, however we do not terminate ourselves if it remains unhandled


            let next: Behavior<Message>
            if case .signalHandling = self.behavior {
                // TODO we always want to call "through" the supervisor, make it more obvious that that should be the case internal API wise?
                next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)
            } else {
                // no signal handling installed is semantically equivalent to unhandled
                // log.debug("No .signalHandling installed, yet \(message) arrived; Assuming .unhandled")
                next = Behavior<Message>.unhandled
            }

            try becomeNext(behavior: next)
        }
    }
}

extension ActorCell: CustomStringConvertible {
    public var description: String {
        let path = self._myselfInACell.path.description
        return "\(type(of: self))(\(path))"
    }
}

internal protocol FailableActorCell {
    /// Call only from a crash handler. As assumptions are made that the actor's current thread will never proceed.
    func crashFail(error: Error)
}

/// The purpose of this cell is to allow storing cells of different types in a collection, i.e. Children
internal protocol AbstractCell {

    // MARK: Cell contract

    var _myselfReceivesSystemMessages: ReceivesSystemMessages { get }
    var _children: Children { get }

    // MARK: Internal generic capabilities

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T>
}

extension AbstractCell {
    @inlinable
    var receivesSystemMessages: ReceivesSystemMessages {
        return self._myselfReceivesSystemMessages
    }

    @inlinable
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        switch visit(context, self._myselfReceivesSystemMessages) {
        case .return(let ret): return .result(ret)
        case .abort(let err): return .failed(err)

        case .continue:
            let res = self._children._traverse(context: context.deeper, visit)
            return res
        case .accumulateSingle(let t): // TODO is it worth doing this optimization to avoid the array alloc?
            var c = context.deeper
            c.accumulated.append(t)
            let res = self._children._traverse(context: c, visit)
            return res
        case .accumulateMany(let ts):
            var c = context.deeper
            c.accumulated.append(contentsOf: ts)
            let res = self._children._traverse(context: c, visit)
            return res
        }
    }
}
