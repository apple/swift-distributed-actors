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
public class ActorContext<Message>: ActorRefFactory { // FIXME should IS-A ActorRefFactory

    /// Returns `ActorSystem` which this context belongs to.
    public var system: ActorSystem {
        return undefined()
    }

    /// Uniquely identifies this actor by its path and unique identifier in the current actor hierarchy.
    /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
    ///
    /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
    /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO: wording must match the semantics we decide on for supervision
    public var path: UniqueActorPath {
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

    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: Timers<Message> {
        return undefined()
    }


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
    @discardableResult
    public func watch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> { // TODO: fix signature, should return the watchee
        return undefined()
    }

    internal func watch(_ watchee: BoxedHashableAnyReceivesSystemMessages) {
        return undefined()
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    @discardableResult
    public func unwatch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        return undefined()
    }

    // MARK: Child actor management

    public func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    public func spawnAnonymous<M>(_ behavior: Behavior<M>, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// - SeeAlso: `spawn` and `watch`.
    public func spawnWatched<M>(_ behavior: Behavior<M>, name: String, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// - SeeAlso: `spawn` and `watch`.
    public func spawnWatchedAnonymous<M>(_ behavior: Behavior<M>, props: Props = Props()) throws -> ActorRef<M> {
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
    /// - Throws: when an actor ref is passed in that is NOT a child of the current actor.
    ///         An actor may not terminate another's child actors.
    public func stop<M>(child ref: ActorRef<M>) throws {
        return undefined()
    }

    /// Turns a closure into an `AsynchronousCallback` that is executed in the context of this actor. It is safe to close over and modify
    /// internal actor state from within an `AsynchronousCallback`.
    ///
    /// Asynchronous callbacks are enqueued wrapped as _messages_, not _signals_, and thus can not be used directly to invoke
    /// an actor which is not processing messages (e.g. is suspended, or for some other reason).
    ///
    /// - Parameter callback: the closure that should be executed in this actor's context
    /// - Returns: an `AsynchronousCallback` that is safe to call from outside of this actor
    @usableFromInline
    internal func makeAsynchronousCallback<T>(_ callback: @escaping (T) throws -> Void) -> AsynchronousCallback<T> {
        return AsynchronousCallback(callback: callback) { [weak selfRef = self.myself._downcastUnsafe] in
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
    ///   - task: result of an asynchronous operation the actor is waiting for
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `AsyncResult` completes
    public func awaitResult<AR: AsyncResult>(of task: AR, timeout: TimeAmount, _ continuation: @escaping (Result<AR.Value, ExecutionError>) throws -> Behavior<Message>) -> Behavior<Message> {
            task.withTimeout(after: timeout).onComplete { [weak selfRef = self.myself._downcastUnsafe] result in
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
    ///   - task: result of an asynchronous operation the actor is waiting for
    ///   - continuation: continuation to run after `AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `AsyncResult` completes
    public func awaitResultThrowing<AR: AsyncResult>(
        of task: AR,
        timeout: TimeAmount,
        _ continuation: @escaping (AR.Value) throws -> Behavior<Message>) -> Behavior<Message> {
            return self.awaitResult(of: task, timeout: timeout) { result in
                switch result {
                case .success(let res):   return try continuation(res)
                case .failure(let error): throw error.underlying
                }
            }
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
