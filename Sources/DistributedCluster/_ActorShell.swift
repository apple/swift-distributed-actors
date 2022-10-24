//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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

/// INTERNAL API
///
/// The shell is responsible for interpreting messages using the current behavior.
/// In simplified terms, it can be thought of as "the actual actor," as it is the most central piece where
/// all actor interactions with messages, user code, and the mailbox itself happen.
///
/// The shell is mutable, and full of dangerous and carefully threaded/ordered code, be extra cautious.
// TODO: remove this and replace by the infrastructure which is now Swift's `actor`
public final class _ActorShell<Message: Codable>: _ActorContext<Message>, AbstractShellProtocol {
    // The phrase that "actor change their behavior" can be understood quite literally;
    // On each message interpretation the actor may return a new behavior that will be handling the next message.
    @usableFromInline
    var behavior: _Behavior<Message>

    @usableFromInline
    let _parent: _AddressableActorRef

    @usableFromInline
    let _id: ActorID

    let _props: _Props

    var namingContext: ActorNamingContext

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Instrumentation

    @usableFromInline
    let metrics: ActiveActorMetrics

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Basic ActorContext capabilities

    @usableFromInline
    internal let _dispatcher: MessageDispatcher

    @usableFromInline
    internal var _system: ClusterSystem?

    override public var system: ClusterSystem {
        if let system = self._system {
            return system
        } else {
            return fatalErrorBacktrace(
                """
                Accessed context.system (of actor: \(self.id)) while system was already stopped and released, this should never happen. \
                This may indicate that the context was stored somewhere or passed to another asynchronously executing non-actor context, \
                which is always a programming bug (!). An actor's context MUST NOT ever be accessed by anyone else rather than the actor itself.
                """)
        }
    }

    /// Guaranteed to be set during _ActorRef creation
    /// Must never be exposed to users, rather expose the `_ActorRef<Message>` by calling `myself`.
    @usableFromInline
    lazy var _myCell: _ActorCell<Message> =
        .init(
            id: self.id,
            actor: self,
            mailbox: _Mailbox(shell: self)
        )

    var _myselfReceivesSystemMessages: _ReceivesSystemMessages {
        self.myself
    }

    @usableFromInline
    var asAddressable: _AddressableActorRef {
        self.myself.asAddressable
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: _BehaviorTimers

    override public var timers: _BehaviorTimers<Message> {
        self._timers
    }

    lazy var _timers: _BehaviorTimers<Message> = _BehaviorTimers(context: self)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Fault handling infrastructure

    // We always have a supervisor in place, even if it is just the ".stop" one.
    internal let supervisor: Supervisor<Message>
    // TODO: we can likely optimize not having to call "through" supervisor if we are .stop anyway

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Hacky internal trickery to stop an actor from the outside (but same execution context)

    override internal func _forceStop() {
        do {
            try self.becomeNext(behavior: .stop(reason: .stopMyself))
        } catch {
            self.log.warning("Illegal attempt to stop actor!")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch infrastructure

    // Implementation of DeathWatch
    @usableFromInline internal var _deathWatch: DeathWatchImpl<Message>?
    @usableFromInline internal var deathWatch: DeathWatchImpl<Message> {
        get {
            self._deathWatch!
        }
        _modify {
            guard var d = self._deathWatch else {
                fatalError("BUG! Tried to access deathWatch on \(self.id) and it was nil! Maybe a message was handled after tombstone?")
            }
            self._deathWatch = nil
            defer { self._deathWatch = d }
            yield &d
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: _ActorShell implementation

    internal init(
        system: ClusterSystem, parent: _AddressableActorRef,
        behavior: _Behavior<Message>, id: ActorID,
        props: _Props, dispatcher: MessageDispatcher
    ) {
        self._system = system
        self._parent = parent
        self._dispatcher = dispatcher

        self.behavior = behavior
        self._id = id
        self._props = props
        self._log = Logger.make(system.log, path: id.path)

        self.supervisor = _Supervision.supervisorFor(system, initialBehavior: behavior, props: props.supervision)
        self._deathWatch = DeathWatchImpl(nodeDeathWatcher: system._nodeDeathWatcherStore.load()?.value ?? system.deadLetters.adapted())

        self.namingContext = ActorNamingContext()

        self.metrics = ActiveActorMetrics(system: system, id: id, props: props.metrics)

        // TODO: replace with TestMetrics which we could use to inspect the start/stop counts
        #if SACT_TESTS_LEAKS
        // We deliberately only count user actors here, because the number of
        // system actors may change over time and they are also not relevant for
        // this type of test.
        if id.segments.first?.value == "user" {
            system.userCellInitCounter.loadThenWrappingIncrement(ordering: .relaxed)
        }
        #endif

        super.init()

        system.metrics.recordActorStart(self)
    }

    deinit {
        traceLog_Cell("deinit cell \(self._id)")
        #if SACT_TESTS_LEAKS
        if self.id.segments.first?.value == "user" {
            self.system.userCellInitCounter.loadThenWrappingDecrement(ordering: .relaxed)
        }
        #endif
        self.system.metrics.recordActorStop(self)

        self._system = nil
    }

    /// INTERNAL API: MUST be called immediately after constructing the cell and ref,
    /// as the actor needs to access its ref from its context during setup or other behavior reductions
    internal func set(ref: _ActorCell<Message>) {
        self._myCell = ref // TODO: atomic?
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Children

    private let _childrenLock = ReadWriteLock()
    // All access must be protected with `_childrenLock`, or via `children` helper
    internal var _children: _Children = .init()
    override public var children: _Children {
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Conforming to ActorContext

    /// Returns this actors "self" actor reference, which can be freely shared across
    /// threads, actors, and even nodes (if clustering is used).
    ///
    /// Warning: Do not use after actor has terminated (!)
    override public var myself: _ActorRef<Message> {
        .init(.cell(self._myCell))
    }

    override public var props: _Props {
        self._props
    }

    override public var id: ActorID {
        self._id
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var path: ActorPath {
        self._id.path
    }

    // Implementation note: Watch out when accessing from outside of an actor run, myself could have been unset (!)
    override public var name: String {
        self._id.name
    }

    // access only from within actor
    private var _log: Logger
    override public var log: Logger {
        get {
            self._log
        }
        set {
            self._log = newValue
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Interpreting messages

    var runState: ActorRunResult {
        if self.continueRunning {
            return .continueRunning
        } else if self.isSuspended {
            return .shouldSuspend
        } else {
            return .shouldStop
        }
    }

    /// Interprets the incoming message using the current `_Behavior` and swaps it with the
    /// next behavior (as returned by user code, which the message was applied to).
    ///
    /// Warning: Mutates the cell's behavior.
    /// Returns: `true` if the actor remains alive, and `false` if it now is becoming `.stop`
    func interpretMessage(message: Message) throws -> ActorRunResult {
        do {
            let next: _Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, message: message)

            #if SACT_TRACE_ACTOR_SHELL
            self.log.info("Applied [\(message)]:\(type(of: message)), becoming: \(next)")
            #endif // TODO: make the \next printout nice TODO dont log messages (could leak pass etc)

            let runResult = try self.finishInterpretAnyMessage(next)
            return runResult
        } catch {
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
            let terminated = _Signals.Terminated(id: ref.id, existenceConfirmed: existenceConfirmed, nodeTerminated: nodeTerminated)
            try self.interpretTerminatedSignal(who: ref.id, terminated: terminated)

        case .childTerminated(let ref, let circumstances):
            switch circumstances {
            // escalation takes precedence over death watch in terms of how we report errors
            case .escalating(let failure):
                // we only populate `escalation` if the child is escalating
                let terminated = _Signals._ChildTerminated(id: ref.id, escalation: failure)
                try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)

            case .stopped:
                let terminated = _Signals._ChildTerminated(id: ref.id, escalation: nil)
                try self.interpretChildTerminatedSignal(who: ref, terminated: terminated)
            case .failed:
                let terminated = _Signals._ChildTerminated(id: ref.id, escalation: nil)
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
            self.log.warning(
                "Received adapted message [\(carry.message)]:\(type(of: carry.message as Any)) for which no adapter was registered.",
                metadata: [
                    "actorRef/adapters": "\(self.messageAdapters)",
                ]
            )
            try self.becomeNext(behavior: .ignore) // TODO: make .drop once implemented
            return self.runState
        }

        let next: _Behavior<Message>
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
    internal func finishInterpretAnyMessage(_ next: _Behavior<Message>) throws -> ActorRunResult {
        if next.isChanging {
            try self.becomeNext(behavior: next)
        }

        if !self.behavior.isStillAlive {
            self.children.stopAll()
        }

        return self.runState
    }

    internal var continueRunning: Bool {
        switch self.behavior.underlying {
        case .suspended: return false
        case .stop, .failed: return self.children.nonEmpty
        default: return true
        }
    }

    @usableFromInline
    internal var isSuspended: Bool {
        self.behavior.isSuspended
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

    internal func _escalate(failure: _Supervision.Failure) -> _Behavior<Message> {
        self.behavior = self.behavior.fail(cause: failure)

        return self.behavior
    }

    /// Similar to `fail` however assumes that the current mailbox run will never complete, which can happen when we crashed,
    /// and invoke this function from a signal handler.
    public func reportCrashFail(cause: _MessageProcessingFailure) {
        // if supervision or configurations or failure domain dictates something else will happen, explain it to the user here
        let crashHandlingExplanation = "Terminating actor, process and thread remain alive."

        self.log.error("Actor crashing, reason: [\(cause)]:\(type(of: cause)). \(crashHandlingExplanation)")

        self.behavior = self.behavior.fail(cause: .fault(cause))
    }

    /// Used by supervision, from failure recovery.
    /// In such case the cell must be restarted while the mailbox remain in-tact.
    ///
    /// - Warning: This call MAY throw if user code would throw in reaction to interpreting `_PreRestart`;
    ///            If this happens the actor MUST be terminated immediately as we suspect things went very bad™ somehow.
    @inlinable public func _restartPrepare() throws {
        self.children.stopAll(includeAdapters: false)
        self.timers.cancelAll() // TODO: cancel all except the restart timer

        /// Yes, we ignore the behavior returned by pre-restart on purpose, the supervisor decided what we should `become`,
        /// and we can not change this decision; at least not in the current scheme (which is simple and good enough for most cases).
        _ = try self.behavior.interpretSignal(context: self, signal: _Signals._PreRestart())

        // NOT interpreting Start yet, as it may have to be done after a delay
    }

    /// Used by supervision.
    /// MUST be preceded by an invocation of `restartPrepare`.
    /// The two steps MAY be performed in different point in time; reason being: backoff restarts,
    /// which need to suspend the actor, and NOT start it just yet, until the system message awakens it again.
    public func _restartComplete(with behavior: _Behavior<Message>) throws -> _Behavior<Message> {
        try behavior.validateAsInitial()
        self.behavior = behavior
        try self.interpretStart()
        return self.behavior
    }

    /// Encapsulates logic that has to always be triggered on a state transition to specific behaviors
    /// Always invoke `becomeNext` rather than assigning to `self.behavior` manually.
    ///
    /// Returns: `true` if next behavior is .stop and appropriate actions will be taken
    internal func becomeNext(behavior next: _Behavior<Message>) throws {
        // TODO: handling "unhandled" would be good here... though I think type wise this won't fly, since we care about signal too
        self.behavior = try self.behavior.canonicalize(self, next: next)
    }

    internal func interpretStart() throws {
        // start means we need to evaluate all `setup` blocks, since they need to be triggered eagerly
        traceLog_Cell("START with behavior: \(self.behavior)")

        let started = try self.supervisor.startSupervised(target: self.behavior, context: self)
        try self.becomeNext(behavior: started)
    }

    /// Interpret a `resume` with the passed in result, potentially waking up the actor from `suspended` state.
    /// Interpreting a resume NOT in suspended state is an error and should never happen.
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Lifecycle and DeathWatch interactions

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

        let myAddress: ActorID? = self._myCell.id
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
        // correctness is ensured though, since the parent always receives the `_ChildTerminated`.
        self.notifyParentOfTermination()
        self.notifyWatchersOfTermination()

        do {
            _ = try self.behavior.interpretSignal(context: self, signal: _Signals._PostStop())
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
        traceLog_DeathWatch("NOTIFY WATCHERS WE ARE DEAD self: \(self.id)")
        self.deathWatch.notifyWatchersWeDied(myself: self.myself)
    }

    func notifyParentOfTermination() {
        let parent: _AddressableActorRef = self._parent
        traceLog_DeathWatch("NOTIFY PARENT WE ARE DEAD, myself: [\(self.id)], parent [\(parent.id)]")

        guard case .failed(_, let failure) = self.behavior.underlying else {
            // we are not failed, so no need to further check for .escalate supervision
            return parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable, .stopped))
        }

        guard self.supervisor is EscalatingSupervisor<Message> else {
            // NOT escalating
            return parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable, .failed(failure)))
        }

        parent._sendSystemMessage(.childTerminated(ref: self.myself.asAddressable, .escalating(failure)))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spawn implementations

    @discardableResult
    override public func _spawn<M>(
        _ naming: _ActorNaming,
        of type: M.Type = M.self,
        props: _Props = _Props(),
        file: String = #filePath, line: UInt = #line,
        _ behavior: _Behavior<M>
    ) throws -> _ActorRef<M>
        where M: Codable
    {
        try self.system.serialization._ensureSerializer(type, file: file, line: line)
        return try self._spawn(naming, props: props, behavior)
    }

    @discardableResult
    override public func _spawnWatch<Message>(
        _ naming: _ActorNaming,
        of type: Message.Type = Message.self,
        props: _Props = _Props(),
        file: String = #filePath, line: UInt = #line,
        _ behavior: _Behavior<Message>
    ) throws -> _ActorRef<Message>
        where Message: Codable
    {
        self.watch(try self._spawn(naming, props: props, behavior))
    }

    override public func stop<Message: Codable>(child ref: _ActorRef<Message>) throws {
        try self._stop(child: ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch

    @discardableResult
    override public func watch<Watchee>(
        _ watchee: Watchee,
        with terminationMessage: Message? = nil,
        file: String = #filePath, line: UInt = #line
    ) -> Watchee where Watchee: _DeathWatchable {
        self.deathWatch.watch(watchee: watchee, with: terminationMessage, myself: self, file: file, line: line)
        return watchee
    }

    @discardableResult
    override public func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #filePath, line: UInt = #line
    ) -> Watchee where Watchee: _DeathWatchable {
        self.deathWatch.unwatch(watchee: watchee, myself: self.myself, file: file, line: line)
        return watchee
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sub Receive

    var subReceives: [_AnySubReceiveId: ((SubMessageCarry) throws -> _Behavior<Message>, _AbstractAdapter)] = [:]

    @usableFromInline
    override func subReceive(identifiedBy identifier: _AnySubReceiveId) -> ((SubMessageCarry) throws -> _Behavior<Message>)? {
        self.subReceives[identifier]?.0
    }

    override public func subReceive<SubMessage>(_ id: _SubReceiveId<SubMessage>, _ subType: SubMessage.Type, _ closure: @escaping (SubMessage) throws -> Void) -> _ActorRef<SubMessage>
        where SubMessage: Codable
    {
        do {
            let wrappedClosure: (SubMessageCarry) throws -> _Behavior<Message> = { carry in
                guard let message = carry.message as? SubMessage else {
                    self.log.warning("Received message [\(carry.message)] of type [\(String(reflecting: type(of: carry.message)))] for identifier [\(carry.identifier)] and address [\(carry.subReceiveAddress)] ")
                    return .same // TODO: make .drop once implemented
                }

                try closure(message)
                return .same
            }

            let identifier = _AnySubReceiveId(id)
            if let (_, existingRef) = self.subReceives[identifier] {
                self.subReceives[identifier] = (wrappedClosure, existingRef)
                guard let adapter = existingRef as? SubReceiveAdapter<SubMessage, Message> else {
                    fatalError("Existing ref for sub receive id [\(id)] has unexpected type [\(String(reflecting: type(of: existingRef)))], expected [\(String(reflecting: SubMessage.self))]")
                }
                return .init(.adapter(adapter))
            }

            let naming = _ActorNaming(unchecked: .prefixed(prefix: "$sub-\(id.id)", suffixScheme: .letters))
            let name = naming.makeName(&self.namingContext)
            let adaptedAddress = try self.id.makeChildAddress(name: name, incarnation: .random()) // TODO: actor name to BE the identity
            let ref = SubReceiveAdapter(SubMessage.self, owner: self.myself, id: adaptedAddress, identifier: identifier)

            self._children.insert(ref) // TODO: separate adapters collection?
            self.subReceives[identifier] = (wrappedClosure, ref)
            return .init(.adapter(ref))
        } catch {
            fatalError("""
            Failed while creating a sub receive with id [\(id.id)] and type [\(subType)]. This should never happen, since sub receives have unique names \
            generated for them using sequential names. Maybe `ActorContext.subReceive` was accessed concurrently (which is unsafe!)? \
            Error: \(error)
            """)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Message Adapter

    private var messageAdapter: _ActorRefAdapter<Message>?
    private var messageAdapters: [MessageAdapterClosure] = []
    struct MessageAdapterClosure {
        /// The metatype of the expected incoming parameter; it will be cast and handled by the erased closure.
        ///
        /// We need to store the metatype, because we need `is` relationship to support adapters over classes
        let metaType: AnyMetaType
        let closure: (Any) -> Message?
    }

    override public func messageAdapter<From>(from fromType: From.Type, adapt: @escaping (From) -> Message?) -> _ActorRef<From>
        where From: Codable
    {
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

            if let adapter: _ActorRefAdapter<Message> = self.messageAdapter {
                return .init(.adapter(adapter))
            } else {
                let adaptedAddress = try self.id.makeChildAddress(name: _ActorNaming.adapter.makeName(&self.namingContext), incarnation: .wellKnown)
                let adapter = _ActorRefAdapter(fromType: fromType, to: self.myself, id: adaptedAddress)

                self.messageAdapter = adapter
                self._children.insert(adapter) // TODO: separate adapters collection?

                return .init(.adapter(adapter))
            }
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

extension _ActorShell {
    func interpretSystemWatch(watcher: _AddressableActorRef) {
        if self.behavior.isStillAlive {
            self.deathWatch.becomeWatchedBy(watcher: watcher, myself: self.myself, parent: self._parent)
        } else {
            // so we are in the middle of terminating already anyway
            watcher._sendSystemMessage(.terminated(ref: self.asAddressable, existenceConfirmed: true))
        }
    }

    @inlinable func interpretSystemUnwatch(watcher: _AddressableActorRef) {
        self.deathWatch.removeWatchedBy(watcher: watcher, myself: self.myself)
    }

    /// Interpret incoming .terminated system message
    ///
    /// Mutates actor cell behavior.
    /// May cause actor to terminate upon error or returning .stop etc from `.signalHandling` user code.
    func interpretTerminatedSignal(who dead: ActorID, terminated: _Signals.Terminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received terminated: \(dead)")
        #endif

        let terminatedDirective = self.deathWatch.receiveTerminated(terminated)

        let next: _Behavior<Message>
        if self.props._distributedActor {
            next = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: terminated)
        } else {
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
        }

        switch next.underlying {
        case .unhandled:
            throw DeathPactError.unhandledDeathPact(
                dead, myself: self.myself.asAddressable,
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
    func interpretNodeTerminated(_ terminatedNode: UniqueNode) {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received address terminated: \(terminatedNode)")
        #endif

        self.deathWatch.receiveNodeTerminated(terminatedNode, myself: self.asAddressable)
    }

    /// Interpret a carried signal directly -- those are potentially delivered by plugins or custom transports.
    /// They MAY share semantics with `Signals.Terminated`, in which case they would be interpreted accordingly.
    func interpretCarrySignal(_ signal: _Signal) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received carried signal: \(signal)")
        #endif

        if let terminated = signal as? _Signals.Terminated {
            // it is a Terminated sub-class, and thus shares semantics with it.
            try self.interpretTerminatedSignal(who: terminated.id, terminated: terminated)
        } else {
            let next: _Behavior<Message> = try self.supervisor.interpretSupervised(target: self.behavior, context: self, signal: signal)
            try self.becomeNext(behavior: next)
        }
    }

    func interpretStop() throws {
        self.children.stopAll()
        try self.becomeNext(behavior: .stop(reason: .stopByParent))
    }

    func interpretChildTerminatedSignal(who terminatedRef: _AddressableActorRef, terminated: _Signals._ChildTerminated) throws {
        #if SACT_TRACE_ACTOR_SHELL
        self.log.info("Received \(terminated)")
        #endif

        // we always first need to remove the now terminated child from our children
        _ = self.children.removeChild(identifiedBy: terminatedRef.id)
        // Implementation notes:
        // Normally this does not happen, however it MAY occur when the parent actor (self)
        // immediately performed a `stop()` on the child, and thus removes it from its
        // children container immediately; The following termination notification would therefore
        // reach the parent in which the child was already removed.

        // next we may apply normal deathWatch logic if the child was being watched
        if self.deathWatch.isWatching(terminatedRef.id) {
            return try self.interpretTerminatedSignal(who: terminatedRef.id, terminated: terminated)
        } else {
            // otherwise we deliver the message, however we do not terminate ourselves if it remains unhandled

            let next: _Behavior<Message>
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

                    next = try self.supervisor.interpretSupervised(
                        target: .signalHandling(
                            handleMessage: self.behavior,
                            handleSignal: { _, _ in
                                switch failure {
                                case .error(let error):
                                    throw error
                                case .fault(let errorRepr):
                                    throw errorRepr
                                }
                            }
                        ),
                        context: self,
                        signal: terminated
                    )

                case .none:
                    // the child actor has stopped without providing us with a reason // FIXME; does this need to carry manual stop as a reason?
                    //
                    // no signal handling installed is semantically equivalent to unhandled
                    next = _Behavior<Message>.unhandled
                }
            }

            try self.becomeNext(behavior: next)
        }
    }
}

extension _ActorShell: CustomStringConvertible {
    public var description: String {
        let prettyTypeName = String(reflecting: Message.self).split(separator: ".").dropFirst().joined(separator: ".")
        return "ActorContext<\(prettyTypeName)>(\(self.path))"
    }
}

/// The purpose of this cell is to allow storing cells of different types in a collection, i.e. Children
internal protocol AbstractShellProtocol: _ActorTreeTraversable {
    var _myselfReceivesSystemMessages: _ReceivesSystemMessages { get }
    var children: _Children { get set } // lock-protected
    var asAddressable: _AddressableActorRef { get }
    var metrics: ActiveActorMetrics { get }
}

extension AbstractShellProtocol {
    @inlinable
    var receivesSystemMessages: _ReceivesSystemMessages {
        self._myselfReceivesSystemMessages
    }

    public func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        let directive = visit(context, self.asAddressable)

        switch directive {
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

    public func _resolve<Message>(context: _ResolveContext<Message>) -> _ActorRef<Message>
        where Message: Codable
    {
        let myself: _ReceivesSystemMessages = self._myselfReceivesSystemMessages

        do {
            try context.system.serialization._ensureSerializer(Message.self)
        } catch {
            context.system.log.warning("Failed to ensure serializer for \(String(reflecting: Message.self))")
            return context.personalDeadLetters
        }

        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if myself.id.incarnation == context.id.incarnation {
                switch myself {
                case let myself as _ActorRef<Message>:
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

    public func _resolveUntyped(context: _ResolveContext<Never>) -> _AddressableActorRef {
        guard context.selectorSegments.first != nil else {
            // no remaining selectors == we are the "selected" ref, apply uid check
            if self._myselfReceivesSystemMessages.id.incarnation == context.id.incarnation {
                return self.asAddressable
            } else {
                // the selection was indeed for this path, however we are a different incarnation (or different actor)
                return context.personalDeadLetters.asAddressable
            }
        }

        return self.children._resolveUntyped(context: context)
    }
}

extension _ActorContext {
    /// INTERNAL API: UNSAFE, DO NOT TOUCH.
    @usableFromInline
    internal var _downcastUnsafe: _ActorShell<Message> {
        switch self {
        case let shell as _ActorShell<Message>: return shell
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to ActorCell. This is a bug, please report this on the issue tracker.")
        }
    }
}
