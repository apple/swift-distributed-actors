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

import CDistributedActorsMailbox
import Logging
import Metrics
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor internals

/// :nodoc: INTERNAL API
///
/// The shell is responsible for interpreting messages using the current behavior.
/// In simplified terms, it can be thought of as "the actual actor," as it is the most central piece where
/// all actor interactions with messages, user code, and the mailbox itself happen.
///
/// The shell is mutable, and full of dangerous and carefully threaded/ordered code, be extra cautious.
public final class ActorShell<Message>: ActorContext<Message>, AbstractActor {
    // The phrase that "actor change their behavior" can be understood quite literally;
    // On each message interpretation the actor may return a new behavior that will be handling the next message.
    @usableFromInline
    var behavior: Behavior<Message>

    let _parent: AddressableActorRef

    let _address: ActorAddress

    let _props: Props

    var namingContext: ActorNamingContext

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Instrumentation

    @usableFromInline
    var instrumentation: ActorInstrumentation!

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Basic ActorContext capabilities

    @usableFromInline
    internal let _dispatcher: MessageDispatcher

    @usableFromInline
    var _system: ActorSystem
    public override var system: ActorSystem {
        self._system
    }

    /// Guaranteed to be set during ActorRef creation
    /// Must never be exposed to users, rather expose the `ActorRef<Message>` by calling `myself`.
    @usableFromInline
    lazy var _myCell: ActorCell<Message> =
        ActorCell<Message>(
            address: self.address,
            actor: self,
            mailbox: Mailbox(shell: self, capacity: self._props.mailbox.capacity)
        )

    @usableFromInline
    var _myselfReceivesSystemMessages: _ReceivesSystemMessages {
        return self.myself
    }

    @usableFromInline
    var asAddressable: AddressableActorRef {
        return self.myself.asAddressable()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timers

    public override var timers: Timers<Message> {
        return self._timers
    }

    lazy var _timers: Timers<Message> = Timers(context: self)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Fault handling infrastructure

    // We always have a supervisor in place, even if it is just the ".stop" one.
    @usableFromInline internal let supervisor: Supervisor<Message>
    // TODO: we can likely optimize not having to call "through" supervisor if we are .stop anyway

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Defer

    @usableFromInline
    internal let deferred = DefersContainer()

    public override func `defer`(
        until: DeferUntilWhen,
        file: String = #file, line: UInt = #line,
        _ closure: @escaping () -> Void
    ) {
        do {
            let deferred = ActorDeferredClosure(until: until, closure, file: file, line: line)
            try self.deferred.push(deferred)
        } catch {
            // FIXME: Only reason this fails silently and not fatalErrors is since it would easily get into crash looping infinitely...
            self.log.error("Attempted to invoke context.defer nested in another context.defer execution. This is currently not supported. \(error)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch infrastructure

    // Implementation of DeathWatch
    @usableFromInline internal var _deathWatch: DeathWatch<Message>?
    @usableFromInline internal var deathWatch: DeathWatch<Message> {
        get {
            guard let d = self._deathWatch else {
                fatalError("BUG! Tried to access deathWatch on \(self.address) and it was nil!!!! Maybe a message was handled after tombstone?")
            }
            return d
        }
        set {
            self._deathWatch = newValue
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ActorShell implementation

    internal init(
        system: ActorSystem, parent: AddressableActorRef,
        behavior: Behavior<Message>, address: ActorAddress,
        props: Props, dispatcher: MessageDispatcher
    ) {
        self._system = system
        self._parent = parent
        self._dispatcher = dispatcher

        self.behavior = behavior
        self._address = address
        self._props = props

        self.supervisor = Supervision.supervisorFor(system, initialBehavior: behavior, props: props.supervision)

        if let nodeDeathWatcher = system._nodeDeathWatcher {
            self._deathWatch = DeathWatch(nodeDeathWatcher: nodeDeathWatcher)
        } else {
            // FIXME; we could see if `myself` is the right one actually... rather than dead letters; if we know the FIRST actor ever is the failure detector one?
            self._deathWatch = DeathWatch(nodeDeathWatcher: system.deadLetters.adapted())
        }

        self.namingContext = ActorNamingContext()

        // TODO: replace with TestMetrics which we could use to inspect the start/stop counts
        #if SACT_TESTS_LEAKS
        // We deliberately only count user actors here, because the number of
        // system actors may change over time and they are also not relevant for
        // this type of test.
        if address.segments.first?.value == "user" {
            _ = system.userCellInitCounter.add(1)
        }
        #endif

        super.init()

        let addr = address.fillNodeWhenEmpty(system.settings.cluster.uniqueBindNode)
        self.instrumentation = system.settings.instrumentation.makeActorInstrumentation(self, addr)
        self.instrumentation.actorSpawned()
        system.metrics.recordActorStart(self)
    }

    deinit {
        traceLog_Cell("deinit cell \(self._address)")
        #if SACT_TESTS_LEAKS
        if self.address.segments.first?.value == "user" {
            _ = system.userCellInitCounter.sub(1)
        }
        #endif
        self.instrumentation.actorStopped()
        system.metrics.recordActorStop(self)
    }

    /// :nodoc: INTERNAL API: MUST be called immediately after constructing the cell and ref,
    /// as the actor needs to access its ref from its context during setup or other behavior reductions
    internal func set(ref: ActorCell<Message>) {
        self._myCell = ref // TODO: atomic?
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Children

    private let _childrenLock = ReadWriteLock()
    // All access must be protected with `_childrenLock`, or via `children` helper
    internal var _children: Children = Children()
    public override var children: Children {
        set {
            self._childrenLock.lockWrite()
            defer { self._childrenLock.unlock() }
            self._children = newValue
        }
        get {
            self._childrenLock.lockRead()
            defer { self._childrenLock.unlock() }
            return self._children
        }
    }

    func dropMessage(_ message: Message) {
        // TODO: implement support for logging dropped messages; those are different than deadLetters
        pprint("[dropped] Message [\(message)]:\(type(of: message)) was not delivered.")
        // system.deadLetters.tell(Dropped(message)) // TODO metadata
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Conforming to ActorContext

    /// Returns this actors "self" actor reference, which can be freely shared across
    /// threads, actors, and even nodes (if clustering is used).
    ///
    /// Warning: Do not use after actor has terminated (!)
    public override var myself: ActorRef<Message> {
        .init(.cell(self._myCell))
    }

    public override var props: Props {
        self._props
    }

    public override var address: ActorAddress {
        self._address
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    public override var path: ActorPath {
        self._address.path
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    public override var name: String {
        self._address.name
    }

    // access only from within actor
    private lazy var _log = ActorLogger.make(context: self)
    public override var log: Logger {
        get {
            self._log
        }
        set {
            self._log = newValue
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Interpreting messages

    @inlinable
    var runState: ActorRunResult {
        if self.continueRunning {
            return .continueRunning
        } else if self.isSuspended {
            return .shouldSuspend
        } else {
            return .shouldStop
        }
    }

    /// Interprets the incoming message using the current `Behavior` and swaps it with the
    /// next behavior (as returned by user code, which the message was applied to).
    ///
    /// Warning: Mutates the cell's behavior.
    /// Returns: `true` if the actor remains alive, and `false` if it now is becoming `.stop`
    @inlinable
    func interpretMessage(message: Message) throws -> ActorRunResult {
        self.instrumentation.actorReceivedStart(message: message, from: nil)

        do {
            let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: message)

            #if SACT_TRACE_ACTOR_SHELL
            self.log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
            #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

            let runResult = try self.finishInterpretAnyMessage(next)
            self.instrumentation.actorReceivedEnd(error: nil)
            return runResult
        } catch {
            self.instrumentation.actorReceivedEnd(error: error)
            throw error
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling system messages

    /// Process single system message and return if processing of further shall continue.
    /// If not, then they will be drained to deadLetters – as it means that the actor is terminating!
    ///
    /// Throws:
    ///   - user behavior thrown exceptions
    ///   - or `DeathPactError` when a watched actor terminated and the termination signal was not handled; See "death watch" for details.
    func interpretSystemMessage(message: _SystemMessage) throws -> ActorRunResult {
        traceLog_Cell("Interpret system message: \(message)")

        switch message {
        case .start:
            try self.interpretStart()

        // death watch
        case .watch(_, let watcher):
            self.interpretSystemWatch(watcher: watcher)
        case .unwatch(_, let watcher):
            self.interpretSystemUnwatch(watcher: watcher)

        case .terminated(let ref, let existenceConfirmed, let nodeTerminated):
            let terminated = Signals.Terminated(address: ref.address, existenceConfirmed: existenceConfirmed, nodeTerminated: nodeTerminated)
            try self.interpretTerminatedSignal(who: ref.address, terminated: terminated)

        case .childTerminated(let ref, let circumstances):
            switch circumstances {
            // escalation takes precedence over death watch in terms of how we report errors
            case .escalating(let failure):
                // we only populate `escalation` if the child is escalating
                let terminated = Signals.ChildTerminated(address: ref.address, escalation: failure)
                try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)

            case .stopped:
                let terminated = Signals.ChildTerminated(address: ref.address, escalation: nil)
                try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)
            case .failed:
                let terminated = Signals.ChildTerminated(address: ref.address, escalation: nil)
                try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)
            }

        case .nodeTerminated(let remoteNode):
            self.interpretNodeTerminated(remoteNode)

        case .carrySignal(let signal):
            try self.interpretCarrySignal(signal)

        case .stop:
            try self.interpretStop()

        case .resume(let result):
            return try self.interpretResume(result)

        case .tombstone:
            return self.finishTerminating()
        }

        return self.runState
    }

    func interpretClosure(_ closure: ActorClosureCarry) throws -> ActorRunResult {
        let next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, closure: closure)
        traceLog_Cell("Applied closure, becoming: \(next)")

        return try self.finishInterpretAnyMessage(next)
    }

    func interpretAdaptedMessage(_ carry: AdaptedMessageCarry) throws -> ActorRunResult {
        let maybeAdapter = self.messageAdapters.first(where: { adapter in
            adapter.metaType.isInstance(carry.message)
        })

        guard let adapter = maybeAdapter?.closure else {
            self.log.warning("Received adapted message [\(carry.message)]:\(type(of: carry.message)) for which no adapter was registered.")
            try self.becomeNext(behavior: .ignore) // TODO: make .drop once implemented
            return self.runState
        }

        let next: Behavior<Message>
        if let adapted = adapter(carry.message) {
            next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: adapted)
        } else {
            next = .unhandled // TODO: could be .drop
        }
        traceLog_Cell("Applied adapted message \(carry.message), becoming: \(next)")

        return try self.finishInterpretAnyMessage(next)
    }

    func interpretSubMessage(_ subMessage: SubMessageCarry) throws -> ActorRunResult {
        let next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, subMessage: subMessage)
        traceLog_Cell("Applied subMessage \(subMessage.message), becoming: \(next)")

        return try self.finishInterpretAnyMessage(next)
    }

    /// Handles all actions that MUST be applied after a message is interpreted.
    @usableFromInline
    internal func finishInterpretAnyMessage(_ next: Behavior<Message>) throws -> ActorRunResult {
        try self.deferred.invokeAllAfterReceived()

        if next.isChanging {
            try self.becomeNext(behavior: next)
        }

        if !self.behavior.isStillAlive {
            self.children.stopAll()
        }

        return self.runState
    }

    @inlinable
    internal var continueRunning: Bool {
        switch self.behavior.underlying {
        case .suspended: return false
        case .stop, .failed: return self.children.nonEmpty
        default: return true
        }
    }

    @usableFromInline
    internal var isSuspended: Bool {
        return self.behavior.isSuspended
    }

    /// Fails the actor using the passed in error.
    ///
    /// May ONLY be invoked by the Mailbox.
    ///
    /// Special handling is applied to `DeathPactError` since if that error is passed in here, we know that `.terminated`
    /// was not handled and we have to adhere to the DeathPact contract by stopping this actor as well.
    ///
    /// We only FORCE the sending of a tombstone if we know we have parked the thread because an actual failure happened,
    /// thus this run *will never complete* and we have to make sure that we run the cleanup that the tombstone causes.
    /// This means that while the current thread is parked forever, we will enter the mailbox with another last run (!), to process the cleanups.
    @usableFromInline
    internal func fail(_ error: Error) {
        self._myCell.mailbox.setFailed()
        self.behavior = self.behavior.fail(cause: .error(error))

        switch error {
        case DeathPactError.unhandledDeathPact(_, _, let message):
            self.log.error("\(message)") // TODO: configurable logging? in props?

        default:
            self.log.warning("Actor threw error, reason: [\(error)]:\(type(of: error)). Terminating.") // TODO: configurable logging? in props?
        }
    }

    @usableFromInline
    internal func _escalate(failure: Supervision.Failure) -> Behavior<Message> {
        self.behavior = self.behavior.fail(cause: failure)

        return self.behavior
    }

    /// Similar to `fail` however assumes that the current mailbox run will never complete, which can happen when we crashed,
    /// and invoke this function from a signal handler.
    public func reportCrashFail(cause: MessageProcessingFailure) {
        // if supervision or configurations or failure domain dictates something else will happen, explain it to the user here
        let crashHandlingExplanation = "Terminating actor, process and thread remain alive."

        self.log.error("Actor crashing, reason: [\(cause)]:\(type(of: cause)). \(crashHandlingExplanation)")

        self.behavior = self.behavior.fail(cause: .fault(cause))
    }

    /// Used by supervision, from failure recovery.
    /// In such case the cell must be restarted while the mailbox remain in-tact.
    ///
    /// - Warning: This call MAY throw if user code would throw in reaction to interpreting `PreRestart`;
    ///            If this happens the actor MUST be terminated immediately as we suspect things went very bad™ somehow.
    @inlinable public func _restartPrepare() throws {
        self.children.stopAll(includeAdapters: false)
        self.timers.cancelAll() // TODO: cancel all except the restart timer

        // since we are restarting that means that we have failed
        try self.deferred.invokeAllAfterFailing()

        /// Yes, we ignore the behavior returned by pre-restart on purpose, the supervisor decided what we should `become`,
        /// and we can not change this decision; at least not in the current scheme (which is simple and good enough for most cases).
        _ = try self.behavior.interpretSignal(context: self, signal: Signals.PreRestart())

        // NOT interpreting Start yet, as it may have to be done after a delay
    }

    /// Used by supervision.
    /// MUST be preceded by an invocation of `restartPrepare`.
    /// The two steps MAY be performed in different point in time; reason being: backoff restarts,
    /// which need to suspend the actor, and NOT start it just yet, until the system message awakens it again.
    @inlinable public func _restartComplete(with behavior: Behavior<Message>) throws -> Behavior<Message> {
        try behavior.validateAsInitial()
        self.behavior = behavior
        try self.interpretStart()
        return self.behavior
    }

    /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
    /// Always invoke `becomeNext` rather than assigning to `self.behavior` manually.
    ///
    /// Returns: `true` if next behavior is .stop and appropriate actions will be taken
    @inlinable
    internal func becomeNext(behavior next: Behavior<Message>) throws {
        // TODO: handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too
        self.behavior = try self.behavior.canonicalize(self, next: next)
    }

    @inlinable
    internal func interpretStart() throws {
        // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly
        traceLog_Cell("START with behavior: \(self.behavior)")

        let started = try self.supervisor.startSupervised(target: self.behavior, context: self)
        try self.becomeNext(behavior: started)
    }

    /// Interpret a `resume` with the passed in result, potentially waking up the actor from `suspended` state.
    /// Interpreting a resume NOT in suspended state is an error and should never happen.
    @inlinable
    internal func interpretResume(_ result: Result<Any, Error>) throws -> ActorRunResult {
        switch self.behavior.underlying {
        case .suspended(let previousBehavior, let handler):
            let next = try self.supervisor.interpretSupervised(target: previousBehavior, context: self) {
                try handler(result)
            }
            // We need to ensure the behavior is canonicalized, as perhaps the suspension was wrapping setup or similar
            let canonicalizedNext = try previousBehavior.canonicalize(self, next: next)
            return try self.finishInterpretAnyMessage(canonicalizedNext)
        default:
            self.log.error(
                "Received .resume message while being in non-suspended state. Please report this as a bug.",
                metadata: [
                    "result": "\(result)",
                    "behavior": "\(self.behavior)",
                ]
            )
            return self.runState
        }
    }

    // MARK: Lifecycle and DeathWatch TODO move death watch things all into an extension

    // TODO: this is also part of lifecycle / supervision... maybe should be in an extension for those

    /// This is the final method an ActorCell ever runs.
    ///
    /// It notifies any remaining watchers about its termination, releases any remaining resources,
    /// and clears its behavior, allowing state kept inside it to be released as well.
    ///
    /// Once this method returns the cell becomes "terminated", an empty shell, and may never be run again.
    /// This is coordinated with its mailbox, which by then becomes closed, and shall no more accept any messages, not even system ones.
    ///
    /// Any remaining system messages are to be drained to deadLetters by the mailbox in its current run.
    private func finishTerminating() -> ActorRunResult {
        self._myCell.mailbox.setClosed()

        let myAddress: ActorAddress? = self._myCell.address
        traceLog_Cell("FINISH TERMINATING \(self)")

        // TODO: stop all children? depends which style we'll end up with...
        // TODO: the thing is, I think we can express the entire "wait for children to stop" as a behavior, and no need to make it special implementation in the cell

        // when terminating, we need to stop all timers, including system timers
        self.timers._cancelAll(includeSystemTimers: true)

        // notifying parent and other watchers has no ordering guarantees with regards to reception,
        // however let's first notify the parent and then all other watchers (even if parent did watch this child
        // we do not need to send it another terminated message, the terminatedChild is enough).
        //
        // note that even though the parent can (and often does) `watch(child)`, we filter it out from
        // our `watchedBy` set, since otherwise we would have to filter it out when sending the terminated back.
        // correctness is ensured though, since the parent always receives the `ChildTerminated`.
        self.notifyParentOfTermination()
        self.notifyWatchersOfTermination()

        self.invokePendingDeferredClosuresWhileTerminating()

        do {
            _ = try self.behavior.interpretSignal(context: self, signal: Signals.PostStop())
        } catch {
            // TODO: should probably .escalate instead;
            self.log.error("Exception in postStop. Supervision will NOT be applied. Error \(error)")
        }

        // TODO: validate all the niling out; can we null out the cell itself?
        self._deathWatch = nil
        self.messageAdapters = []
        self.subReceives = [:]

        // become stopped, if not already
        switch self.behavior.underlying {
        case .failed(_, let failure):
            self.behavior = .stop(reason: .failure(failure))
        case .stop(_, let reason):
            self.behavior = .stop(reason: reason)
        default:
            self.behavior = .stop
        }

        traceLog_Cell("CLOSED DEAD: \(String(describing: myAddress)) has completely terminated, and will never act again.")

        // It shall act, ah, nevermore!
        return .closed
    }

    // Implementation note: bridge method so Mailbox can call this when needed
    func notifyWatchersOfTermination() {
        traceLog_DeathWatch("NOTIFY WATCHERS WE ARE DEAD self: \(self.address)")
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }

    func notifyParentOfTermination() {
        let parent: AddressableActorRef = self._parent
        traceLog_DeathWatch("NOTIFY PARENT WE ARE DEAD, myself: [\(self.address)], parent [\(parent.address)]")

        guard case .failed(_, let failure) = self.behavior.underlying else {
            // we are not failed, so no need to further check for .escalate supervision
            return parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable(), .stopped))
        }

        guard self.supervisor is EscalatingSupervisor<Message> else {
            // NOT escalating
            return parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable(), .failed(failure)))
        }

        parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable(), .escalating(failure)))
    }

    func invokePendingDeferredClosuresWhileTerminating() {
        do {
            switch self.behavior.underlying {
            case .stop(_, let reason):
                switch reason {
                case .failure:
                    try self.deferred.invokeAllAfterFailing()
                case .stopMyself, .stopByParent:
                    try self.deferred.invokeAllAfterStop()
                }
            case .failed:
                try self.deferred.invokeAllAfterFailing()
            default:
                fatalError("Potential bug. Should only be invoked on .stop / .failed")
            }
        } catch {
            self.log.error("Invoking context.deferred closures threw: \(error), remaining closures will NOT be invoked. Proceeding with termination.")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spawn implementations

    public override func spawn<Message>(_ naming: ActorNaming, of type: Message.Type = Message.self, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self._spawn(naming, props: props, behavior)
    }

    public override func spawnWatch<Message>(_ naming: ActorNaming, of type: Message.Type = Message.self, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        self.watch(try self.spawn(naming, props: props, behavior))
    }

    public override func stop<Message>(child ref: ActorRef<Message>) throws {
        try self._stop(child: ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch API

    public override func watch<M>(_ watchee: ActorRef<M>, with terminationMessage: Message? = nil, file: String = #file, line: UInt = #line) -> ActorRef<M> {
        self.watch(watchee.asAddressable(), with: terminationMessage, file: file, line: line)
        return watchee
    }

    internal override func watch(_ watchee: AddressableActorRef, with terminationMessage: Message? = nil, file: String = #file, line: UInt = #line) {
        self.deathWatch.watch(watchee: watchee, with: terminationMessage, myself: self.myself, parent: self._parent, file: file, line: line)
    }

    public override func unwatch<M>(_ watchee: ActorRef<M>, file: String = #file, line: UInt = #line) -> ActorRef<M> {
        self.unwatch(watchee.asAddressable(), file: file, line: line)
        return watchee
    }

    internal override func unwatch(_ watchee: AddressableActorRef, file: String = #file, line: UInt = #line) {
        self.deathWatch.unwatch(watchee: watchee, myself: self.myself, file: file, line: line)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sub Receive

    var subReceives: [AnySubReceiveId: ((SubMessageCarry) throws -> Behavior<Message>, AbstractAdapter)] = [:]

    @usableFromInline
    override func subReceive(identifiedBy identifier: AnySubReceiveId) -> ((SubMessageCarry) throws -> Behavior<Message>)? {
        return self.subReceives[identifier]?.0
    }

    public override func subReceive<SubMessage>(_ id: SubReceiveId<SubMessage>, _ subType: SubMessage.Type, _ closure: @escaping (SubMessage) throws -> Void) -> ActorRef<SubMessage> {
        do {
            let wrappedClosure: (SubMessageCarry) throws -> Behavior<Message> = { carry in
                guard let message = carry.message as? SubMessage else {
                    self.log.warning("Received message [\(carry.message)] of type [\(String(reflecting: type(of: carry.message)))] for identifier [\(carry.identifier)] and address [\(carry.subReceiveAddress)] ")
                    return .same // TODO: make .drop once implemented
                }

                try closure(message)
                return .same
            }

            let identifier = AnySubReceiveId(id)
            if let (_, existingRef) = self.subReceives[identifier] {
                self.subReceives[identifier] = (wrappedClosure, existingRef)
                guard let adapter = existingRef as? SubReceiveAdapter<SubMessage, Message> else {
                    fatalError("Existing ref for sub receive id [\(id)] has unexpected type [\(String(reflecting: type(of: existingRef)))], expected [\(String(reflecting: SubMessage.self))]")
                }
                return .init(.adapter(adapter))
            }

            let naming = ActorNaming(unchecked: .prefixed(prefix: "$sub-\(id.id)", suffixScheme: .letters))
            let name = naming.makeName(&self.namingContext)
            let adaptedAddress = try self.address.makeChildAddress(name: name, incarnation: .random()) // TODO: actor name to BE the identity
            let ref = SubReceiveAdapter(SubMessage.self, owner: self.myself, address: adaptedAddress, identifier: identifier)

            self._children.insert(ref) // TODO: separate adapters collection?
            self.subReceives[identifier] = (wrappedClosure, ref)
            return .init(.adapter(ref))
        } catch {
            fatalError("""
            Failed while creating a sub receive with id [\(id.id)] and type [\(subType)]. This should never happen, since sub receives have unique names
            generated for them using sequential names. Maybe `ActorContext.subReceive` was accessed concurrently (which is unsafe!)?
            Error: \(error)
            """)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Message Adapter

    private var messageAdapterRef: ActorRefAdapter<Message>?
    struct MessageAdapterClosure {
        let metaType: AnyMetaType
        let closure: (Any) -> Message?
    }

    private var messageAdapters: [MessageAdapterClosure] = []

    public override func messageAdapter<From>(from fromType: From.Type, adapt: @escaping (From) -> Message?) -> ActorRef<From> {
        do {
            let metaType = MetaType(fromType)
            let anyAdapter: (Any) -> Message? = { message in
                guard let typedMessage = message as? From else {
                    fatalError("messageAdapter was applied to message [\(message)] of incompatible type `\(String(reflecting: type(of: message)))` message." +
                        "This should never happen, as at compile-time the message type should have been enforced to be `\(From.self)`.")
                }

                return adapt(typedMessage)
            }

            self.messageAdapters.removeAll(where: { adapter in
                adapter.metaType.is(metaType)
            })

            self.messageAdapters.insert(MessageAdapterClosure(metaType: metaType, closure: anyAdapter), at: self.messageAdapters.startIndex)

            guard let adapterRef = self.messageAdapterRef else {
                let adaptedAddress = try self.address.makeChildAddress(name: ActorNaming.adapter.makeName(&self.namingContext), incarnation: .wellKnown)
                let ref = ActorRefAdapter(self.myself, address: adaptedAddress)
                self.messageAdapterRef = ref

                self._children.insert(ref) // TODO: separate adapters collection?
                return .init(.adapter(ref))
            }

            return .init(.adapter(adapterRef))
        } catch {
            fatalError("""
            Failed while creating message adapter. This should never happen, since message adapters have a unique name.
            Maybe `ActorContext.messageAdapter` was accessed concurrently (which is unsafe!)?
            Error: \(error)
            """)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal system message / signal handling functions

extension ActorShell {
    @inlinable internal func interpretSystemWatch(watcher: AddressableActorRef) {
        if self.behavior.isStillAlive {
            // TODO: make DeathWatch methods available via extension
            self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself)
        } else {
            // so we are in the middle of terminating already anyway
            watcher._sendSystemMessage(.terminated(ref: self.asAddressable, existenceConfirmed: true))
        }
    }

    @inlinable internal func interpretSystemUnwatch(watcher: AddressableActorRef) {
        self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself) // TODO: make DeathWatch methods available via extension
    }

    /// Interpret incoming .terminated system message
    ///
    /// Mutates actor cell behavior.
    /// May cause actor to terminate upon error or returning .stop etc from `.signalHandling` user code.
    @inlinable internal func interpretTerminatedSignal(who dead: ActorAddress, terminated: Signals.Terminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received terminated: \(dead)")
        #endif

        let terminatedDirective = self.deathWatch.receiveTerminated(terminated)

        let next: Behavior<Message>
        switch terminatedDirective {
        case .wasNotWatched:
            // it is not an actor we currently watch, thus we should not take actions nor deliver the signal to the user
            self.log.trace("""
            Actor not known to [\(self.path)], but [\(terminated)] received for it. This may mean we received node terminated earlier, \
            and already have removed the actor from our death watch. 
            """)
            return

        case .signal:
            next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)

        case .customMessage(let customTerminatedMessage):
            next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: customTerminatedMessage)
        }

        switch next.underlying {
        case .unhandled:
            throw DeathPactError.unhandledDeathPact(
                dead, myself: self.myself.asAddressable(),
                message: "DeathPactError: Unhandled [\(terminated)] signal about watched actor [\(dead)]. " +
                    "Handle the `.terminated` signal in `.receiveSignal()` in order react to this situation differently than termination."
            )
        default:
            try self.becomeNext(behavior: next) // FIXME: make sure we don't drop the behavior...?
        }
    }

    /// Interpret incoming .nodeTerminated system message.
    ///
    /// Results in signaling `Terminated` for all of the locally watched actors on the (now terminated) node.
    /// This action is performed concurrently by all actors who have watched remote actors on given node,
    /// and no ordering guarantees are made about which actors will get the Terminated signals first.
    @inlinable
    internal func interpretNodeTerminated(_ terminatedNode: UniqueNode) {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received address terminated: \(terminatedNode)")
        #endif

        self.deathWatch.receiveNodeTerminated(terminatedNode, myself: self.asAddressable)
    }

    /// Interpret a carried signal directly -- those are potentially delivered by plugins or custom transports.
    /// They MAY share semantics with `Signals.Terminated`, in which case they would be interpreted accordingly.
    @inlinable
    internal func interpretCarrySignal(_ signal: Signal) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received carried signal: \(signal)")
        #endif

        if let terminated = signal as? Signals.Terminated {
            // it is a Terminated sub-class, and thus shares semantics with it,
            // e.g. an XPC Service being Invalidated.
            try self.interpretTerminatedSignal(who: terminated.address, terminated: terminated)
        } else {
            let next: Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: signal)
            try self.becomeNext(behavior: next)
        }
    }

    @inlinable
    internal func interpretStop() throws {
        self.children.stopAll()
        try self.becomeNext(behavior: .stop(reason: .stopByParent))
    }

    @inlinable
    internal func interpretChildTerminatedSignal(who terminatedRef: AddressableActorRef, terminated: Signals.ChildTerminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received \(terminated)")
        #endif

        // we always first need to remove the now terminated child from our children
        _ = self.children.removeChild(identifiedBy: terminatedRef.address)
        // Implementation notes:
        // Normally this does not happen, however it MAY occur when the parent actor (self)
        // immediately performed a `stop()` on the child, and thus removes it from its
        // children container immediately; The following termination notification would therefore
        // reach the parent in which the child was already removed.

        // next we may apply normal deathWatch logic if the child was being watched
        if self.deathWatch.isWatching(terminatedRef.address) {
            return try self.interpretTerminatedSignal(who: terminatedRef.address, terminated: terminated)
        } else {
            // otherwise we deliver the message, however we do not terminate ourselves if it remains unhandled

            let next: Behavior<Message>
            if case .signalHandling = self.behavior.underlying {
                // TODO: we always want to call "through" the supervisor, make it more obvious that that should be the case internal API wise?
                next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)
            } else {
                switch terminated.escalation {
                case .some(let failure):
                    // the child actor decided to `.escalate` the error and thus we are notified about it
                    // escalation differs from plain termination that by default it DOES cause us to crash as well,
                    // causing a chain reaction of crashing until someone handles or the guardian receives it and shuts down the system.
                    self.log.warning("Failure escalated by [\(terminatedRef.path)] reached non-watching, non-signal handling parent, escalation will continue! Failure was: \(failure)")

                    next = try self.supervisor.interpretSupervised(target: .signalHandling(
                        handleMessage: self.behavior,
                        handleSignal: { _, _ in
                            switch failure {
                            case .error(let error):
                                throw error
                            case .fault(let errorRepr):
                                throw errorRepr
                            }
                        }
                    ), context: self, signal: terminated)

                case .none:
                    // the child actor has stopped without providing us with a reason // FIXME; does this need to carry manual stop as a reason?
                    //
                    // no signal handling installed is semantically equivalent to unhandled
                    next = Behavior<Message>.unhandled
                }
            }

            try self.becomeNext(behavior: next)
        }
    }
}

extension ActorShell: CustomStringConvertible {
    public var description: String {
        let prettyTypeName = String(reflecting: Message.self).split(separator: ".").dropFirst().joined(separator: ".")
        return "ActorShell<\(prettyTypeName)>(\(self.path))"
    }
}

/// The purpose of this cell is to allow storing cells of different types in a collection, i.e. Children
internal protocol AbstractActor: _ActorTreeTraversable {
    var _myselfReceivesSystemMessages: _ReceivesSystemMessages { get }
    var children: Children { get set } // lock-protected
    var asAddressable: AddressableActorRef { get }
}

extension AbstractActor {
    @inlinable
    var receivesSystemMessages: _ReceivesSystemMessages {
        self._myselfReceivesSystemMessages
    }

    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self.asAddressable) {
        case .continue:
            let res = self.children._traverse(context: c, visit)
            return res
        case .accumulateSingle(let t):
            c.accumulated.append(t)
            return self.children._traverse(context: c, visit)
        case .accumulateMany(let ts):
            c.accumulated.append(contentsOf: ts)
            return self.children._traverse(context: c, visit)
        case .abort(let err):
            return .failed(err)
        }
    }

    public func _resolve<Message: Codable>(context: ResolveContext<Message>) -> ActorRef<Message> {
        return self.__resolve(context: context)
    }
    public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        return self.__resolve(context: context)
    }
    private func __resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        let myself: _ReceivesSystemMessages = self._myselfReceivesSystemMessages

        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if myself.address.incarnation == context.address.incarnation {
                switch myself {
                case let myself as ActorRef<Message>:
                    return myself
                default:
                    return context.personalDeadLetters
                }
            } else {
                // the selection was indeed for this path, however we are a different incarnation (or different actor)
                return context.personalDeadLetters
            }
        }

        return self.children._resolve(context: context)
    }

    public func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if self._myselfReceivesSystemMessages.address.incarnation == context.address.incarnation {
                return self.asAddressable
            } else {
                // the selection was indeed for this path, however we are a different incarnation (or different actor)
                return context.personalDeadLetters.asAddressable()
            }
        }

        return self.children._resolveUntyped(context: context)
    }
}

internal extension ActorContext {
    /// :nodoc: INTERNAL API: UNSAFE, DO NOT TOUCH.
    @usableFromInline
    var _downcastUnsafe: ActorShell<Message> {
        switch self {
        case let shell as ActorShell<Message>: return shell
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to ActorCell. This is a bug, please report this on the issue tracker.")
        }
    }
}
