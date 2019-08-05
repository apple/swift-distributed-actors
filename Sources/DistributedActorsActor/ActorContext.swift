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

import Logging

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// - Warning:
///   - It MUST only ever be accessed from its own Actor. It is fine though to close over it in the actors behaviours.
///   - It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).
public class ActorContext<Message>: ActorRefFactory {

    /// Returns `ActorSystem` which this context belongs to.
    public var system: ActorSystem {
        return undefined()
    }

    /// Uniquely identifies this actor in the cluster.
    public var address: ActorAddress {
        return undefined()
    }

    /// Local path under which this actor resides within the actor tree.
    public var path: ActorPath {
        return undefined()
    }

    /// Name of this actor.
    ///
    /// The `name` is the last segment of the Actor's `path`.
    ///
    /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public var name: String {
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

    /// Provides context metadata aware `Logger`
    public var log: Logger {
        get {
            return undefined()
        }
        set { // has to become settable
            return undefined()
        }
    }

    /// Dispatcher on which this actor is executing
    public var dispatcher: MessageDispatcher {
        return undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timers

    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: Timers<Message> {
        return undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Lifecycle-bound defer

    /// - warning: Experimental API
    ///
    /// Similar to Swift's `defer` however bound to the enclosing actors lifecycle.
    ///
    /// Allows deferring execution of a closure until specified life-cycle event happens.
    /// Most useful for running cleanup upon a fault or error, without having to explicitly prepare setup and `PostStop` signal handlers.
    ///
    /// Care should be taken to not accidentally grow the defer queue infinitely, e.g. always appending a
    /// `defer(until: .termination)` on each handled message, as this way the defer queue could grow infinitely.
    ///
    /// #### Invocation order:
    /// Deferred blocks are invoked in reverse order, while taking into account the lifecycle event to which it was delayed.
    /// E.g. deferring `print("A")` followed by deferring `print("B")` will result in `B` being printed, followed by `A`.
    ///
    /// #### Example Usage:
    /// ```
    /// .receive { context, message in
    ///     let resource = makeResource(message)
    ///
    ///     context.defer(until: .received) {
    ///        context.log.info("Closing (1)")
    ///        resource.complete()
    ///     }
    ///     context.defer(until: .receiveFailed) {
    ///        context.log.info("Marking Failed (2)")
    ///        resource.markFailed()
    ///     }
    ///
    /// // Output, if receive FAILED (threw or soft-faulted) after the defer calls:
    /// - "Closing (1)"
    /// - "Marking Failed (2)"
    ///
    /// // Output, if receive completed successfully (no failures):
    /// - "Closing (1)"
    /// ```
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    public func `defer`(until: DeferUntilWhen,
                        file: String = #file, line: UInt = #line,
                        _ closure: @escaping () -> Void) {
        return undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch

    /// Watches the given actor for termination, which means that this actor will receive a `.terminated` signal
    /// when the watched actor fails ("dies"), be it via throwing a Swift Error or performing some other kind of fault.
    ///
    /// There is no difference between keeping the passed in reference or using the returned ref from this method.
    /// The actor is the being watched subject, not a specific reference to it.
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
    ///
    ///
    /// # Examples:
    ///
    ///     // watch some known ActorRef<M>
    ///     context.watch(someRef)
    ///
    ///     // watch a child actor immediately when spawning it, (entering a death pact with it)
    ///     let child = try context.watch(context.spawn(behavior, name: "child"))
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    @discardableResult
    public func watch<M>(_ watchee: ActorRef<M>, file: String = #file, line: UInt = #line) -> ActorRef<M> { // TODO: fix signature, should return the watchee
        return undefined()
    }

    internal func watch(_ watchee: AddressableActorRef, file: String = #file, line: UInt = #line) {
        return undefined()
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    @discardableResult
    public func unwatch<M>(_ watchee: ActorRef<M>, file: String = #file, line: UInt = #line) -> ActorRef<M> {
        return undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Child actor management

    public func spawn<M>(_ behavior: Behavior<M>, name naming: ActorNaming, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// - SeeAlso: `spawn` and `watch`.
    // TODO spawnAndWatch?
    public func spawnWatched<M>(_ behavior: Behavior<M>, name naming: ActorNaming, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    /// Container of spawned child actors.
    ///
    /// Allows obtaining references to previously spawned actors by their name.
    /// For less dynamic scenarios it is recommended to keep actors refs in your own collection types or as values in your behavior,
    /// since looking up actors by name has an inherent seek cost associated with it.
    public var children: Children {
        get {
            return undefined()
        }
        set {
            return undefined()
        }
    }

    /// Stop a child actor identified by the passed in actor ref.
    ///
    /// **Logs Warnings** when the actor could have been a child of this actor, however it is currently not present in its children container,
    ///    it means that either we attempted to stop an actor "twice" (which is a no-op) or that we are a re-incarnation under the same
    ///    parent math of some actor, and we attempted to stop a non existing child, which also is a no-op however indicates an issue
    ///    in the logic of our actor.
    ///
    /// - Throws: an `ActorContextError` when an actor ref is passed in that is NOT a child of the current actor.
    ///           An actor may not terminate another's child actors. Attempting to stop `myself` using this method will
    ///           also throw, as the proper way of stopping oneself is returning a `Behavior.stop`.
    public func stop<M>(child ref: ActorRef<M>) throws {
        return undefined()
    }

    /// :nodoc: Not intended to be used by end users.
    ///
    /// Turns a closure into an `AsynchronousCallback` that is executed in the context of this actor. It is safe to close over and modify
    /// internal actor state from within an `AsynchronousCallback`.
    ///
    /// Asynchronous callbacks are enqueued wrapped as _messages_, not _signals_, and thus can not be used directly to invoke
    /// an actor which is not processing messages (e.g. is suspended, or for some other reason).
    ///
    /// - Parameter callback: the closure that should be executed in this actor's context
    /// - Returns: an `AsynchronousCallback` that is safe to call from outside of this actor
    @usableFromInline
    internal func makeAsynchronousCallback<T>(file: String = #file, line: UInt = #line, _ callback: @escaping (T) throws -> Void) -> AsynchronousCallback<T> {
        return AsynchronousCallback(callback: callback) { [weak selfRef = self.myself._unsafeUnwrapCell] in
            selfRef?.sendClosure(file: file, line: line, $0)
        }
    }

    /// :nodoc: Not intended to be used by end users.
    ///
    /// Turns a closure into an `AsynchronousCallback` that is executed in the context of this actor. It is safe to close over and modify
    /// internal actor state from within an `AsynchronousCallback`.
    ///
    /// Asynchronous callbacks are enqueued wrapped as _messages_, not _signals_, and thus can not be used directly to invoke
    /// an actor which is not processing messages (e.g. is suspended, or for some other reason).
    ///
    /// - Parameter callback: the closure that should be executed in this actor's context
    /// - Returns: an `AsynchronousCallback` that is safe to call from outside of this actor
    @usableFromInline
    internal func makeAsynchronousCallback<T>(for type: T.Type, callback: @escaping (T) throws -> Void) -> AsynchronousCallback<T> {
        return AsynchronousCallback(callback: callback) { [weak selfRef = self.myself._unsafeUnwrapCell] in
            selfRef?.sendClosure($0)
        }
    }

    /// ***CAUTION***: This functionality should be used with extreme caution, as it will
    ///                stall user message processing for up to the configured timeout.
    ///
    /// While executing a suspension is non-blocking, and the actor will continue processing
    /// system messages, it does hinder the actor from processing any subsequent user messages
    /// until the `task` completes. In other words, it can cause mailbox queue buildup,
    /// if it is receiving many messages while awaiting for the completion signal.
    ///
    /// The behavior returned by the `continuation` is applied as-if it was returned in place of the
    /// returned suspension, i.e. returning .same is legal and means keeping the behavior that
    /// was current at the point where the suspension was initiated. Returning another suspending
    /// behavior is legal, and causes another suspension.
    ///
    /// - Parameters:
    ///   - asyncResult: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the asyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `AsyncResult` completes
    public func awaitResult<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount, _ continuation: @escaping (Result<AR.Value, ExecutionError>) throws -> Behavior<Message>) -> Behavior<Message> {
            asyncResult.withTimeout(after: timeout).onComplete { [weak selfRef = self.myself._unsafeUnwrapCell] result in
                selfRef?.sendSystemMessage(.resume(result.map { $0 }))
            }
            return .suspend(handler: continuation)
    }

    /// ***CAUTION***: This functionality should be used with extreme caution, as it will
    ///                stall user message processing for up to the configured timeout.
    ///
    /// Similar to `awaitResult`, however in case the suspended-on `AsyncTask` completes
    /// with a `.failure`, the behavior will escalate this failure causing the actor to
    /// crash (or be subject to supervision).
    ///
    /// - SeeAlso: `awaitResult`
    /// - Parameters:
    ///   - asyncResult: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the asyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `AsyncResult` completes
    public func awaitResultThrowing<AR: AsyncResult>(
        of asyncResult: AR,
        timeout: TimeAmount,
        _ continuation: @escaping (AR.Value) throws -> Behavior<Message>) -> Behavior<Message> {
            return self.awaitResult(of: asyncResult, timeout: timeout) { result in
                switch result {
                case .success(let res):   return try continuation(res)
                case .failure(let error): throw error.underlying
                }
            }
    }

    /// Applies the result of the `task` to the given `continuation` within the
    /// same actor context, after it completes. The returned behavior will be
    /// assigned as the new behavior of the actor. The actor will keep processing
    /// other incoming messages, while `task` has not been completed, as opposed
    /// to `awaitResult`, which suspends message processing of the actor and
    /// only allows signals to be processed.
    ///
    /// - Parameters:
    ///   - task: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the asyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    public func onResultAsync<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount, _ continuation: @escaping (Result<AR.Value, ExecutionError>) throws -> Behavior<Message>) {
        let asyncCallback = self.makeAsynchronousCallback(for: Result<AR.Value, ExecutionError>.self) {
            let nextBehavior = try continuation($0)
            let shell = self._downcastUnsafe
            shell.behavior = try shell.behavior.canonicalize(shell, next: nextBehavior)
        }

        asyncResult.withTimeout(after: timeout).onComplete { res in
            asyncCallback.invoke(res)
        }
    }

    /// Applies the result of the `task` to the given `continuation` within the
    /// same actor context, after it completes. The returned behavior will be
    /// assigned as the new behavior of the actor. The actor will keep processing
    /// other incoming messages, while `task` has not been completed, as opposed
    /// to `awaitResult`, which suspends message processing of the actor and
    /// only allows signals to be processed.
    ///
    /// In case the given `AsyncTask` completes with a `.failure`, the failure
    /// will be escalated, causing the actor to crash (or be subject to supervision).
    ///
    /// - Parameters:
    ///   - task: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the asyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    public func onResultAsyncThrowing<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount, _ continuation: @escaping (AR.Value) throws -> Behavior<Message>) {
        self.onResultAsync(of: asyncResult, timeout: timeout) { res in
            switch res {
            case .success(let value): return try continuation(value)
            case .failure(let error): throw error.underlying
            }
        }
    }

    /// Adapts this `ActorRef` to accept messages of another type by applying the conversion
    /// function. There can only be one adapter defined per type. Creating a new adapter will
    /// replace an existing adapter.
    ///
    /// The returned `ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `ActorRef` terminates as well.
    public final func messageAdapter<From>(_ adapter: @escaping (From) -> Message) -> ActorRef<From> {
        return self.messageAdapter(from: From.self, with: adapter)
    }

    /// Adapts this `ActorRef` to accept messages of another type by applying the conversion
    /// function. There can only be one adapter defined per type. Creating a new adapter will
    /// replace an existing adapter.
    ///
    /// The returned `ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `ActorRef` terminates as well.
    public func messageAdapter<From>(from type: From.Type, with adapter: @escaping (From) -> Message) -> ActorRef<From> {
        return undefined()
    }

    /// Creates an `ActorRef` that can receive messages of the specified type, but executed in the same
    /// context as the actor owning it, meaning that it is safe to close over mutable state internal to the
    /// surrounding actor and modify it.
    ///
    /// The returned `ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `ActorRef` terminates as well.
    ///
    /// There can only be one `subReceive` per `SubReceiveId`. When installing a new `subReceive`
    /// with an existing `SubReceiveId`, it replaces the old one. All references will remain valid and point to
    /// the new behavior.
    func subReceive<SubMessage>(_ id: SubReceiveId, _ type: SubMessage.Type, _ closure: @escaping (SubMessage) throws -> Void) -> ActorRef<SubMessage> {
        return undefined()
    }

    /// Creates an `ActorRef` that can receive messages of the specified type, but executed in the same
    /// context as the actor owning it, meaning that it is safe to close over mutable state internal to the
    /// surrounding actor and modify it.
    ///
    /// The returned `ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `ActorRef` terminates as well.
    ///
    /// There can only be one `subReceive` per type. When installing a new `subReceive`
    /// with an existing type, it replaces the old one. All references will remain valid and point to
    /// the new behavior.
    func subReceive<SubMessage>(_ type: SubMessage.Type, _ closure: @escaping (SubMessage) throws -> Void) -> ActorRef<SubMessage> {
        return self.subReceive(SubReceiveId(for: type), type, closure)
    }
}

// Used to identify a `subReceive`
public struct SubReceiveId {
    public let id: String

    public init<T>(for type: T.Type) {
        self.id = String(reflecting: type)
    }

    public init(_ id: String) {
        self.id = id
    }

    public init<T>(for type: T.Type, id: String) {
        self.id = "\(String(reflecting: type))-\(id)"
    }
}

extension SubReceiveId: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// Used for the internal ability to schedule a callback to be executed by an actor.
@usableFromInline
internal struct AsynchronousCallback<T> {
    @usableFromInline
    let _callback: (T) throws -> Void
    @usableFromInline
    let _send: (@escaping () throws -> Void) -> Void

    public init(callback: @escaping (T) throws -> Void, send: @escaping (@escaping () throws -> Void) -> Void) {
        self._callback = callback
        self._send = send
    }

    @inlinable
    func invoke(_ arg: T) {
        self._send { try self._callback(arg) }
    }
}
