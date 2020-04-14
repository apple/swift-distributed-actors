//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context

extension Actor {
    /// `Context` of the `Actor`, exposing details and capabilities of the actor, such as spawning, starting timers and similar.
    ///
    /// - ***Warning**: MUST NOT be shared "outside" the actor, as it is only safe to access by the owning actor itself.
    ///
    /// The `Actor<A>.Context` is the `Actorable` equivalent of `ActorContext<Message>`, which is designed to work with the low-level `Behavior` types.
    public struct Context {
        /// Only public to enable workarounds while all APIs gain Actor/Actorable style versions.
        public let _underlying: ActorContext<A.Message>

        public init(underlying: ActorContext<A.Message>) {
            self._underlying = underlying
        }
    }
}

extension Actor.Context {
    /// Returns `ActorSystem` which this context belongs to.
    public var system: ActorSystem {
        self._underlying.system
    }

    /// Uniquely identifies this actor in the cluster.
    public var address: ActorAddress {
        self._underlying.address
    }

    /// Local path under which this actor resides within the actor tree.
    public var path: ActorPath {
        self._underlying.path
    }

    /// Name of this actor.
    ///
    /// The `name` is the last segment of the `Actor`'s `path`.
    ///
    /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public var name: String {
        self._underlying.name
    }

    /// The actor reference to _this_ actor.
    ///
    /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
    /// as such would not be the "same" actor anymore.
    ///
    /// - Concurrency: Must ONLY be accessed by the owning actor.
    //
    // Implementation note:
    // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
    // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
    // to get developers into the right mindset.
    public var myself: Actor<A> {
        Actor(ref: self._underlying.myself)
    }

    /// Provides context metadata aware `Logger`.
    ///
    /// - Concurrency: Must ONLY be accessed by the owning actor.
    public var log: Logger {
        get {
            self._underlying.log
        }
        set {
            self._underlying.log = newValue
        }
    }

    public var props: Props {
        self._underlying.props
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Spawning

extension Actor.Context {
    /// Stops the current actor -- meaning that the current message is the last one it will ever process.
    ///
    /// This function is idempotent (may be called multiple times) and does NOT stop the actor from completing the
    /// currently executing actorable function. The stopping effect will take place after the current receive has completed.
    ///
    /// If this actor had any child actors, they will be stopped as well.
    ///
    /// ### Behavior-stype API Equivalent:
    /// This is equivalent to returning `Behavior.stop` from a `Behavior` style actor receive function.
    ///
    /// - SeeAlso: `Behavior.stop`
    public func stop() {
        self._underlying._forceStop()
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Spawning

extension Actor.Context {
    public func spawn<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (Actor<Child>.Context) -> Child) throws -> Actor<Child> {
        let ref = try self._underlying.spawn(
            naming,
            of: Child.Message.self,
            Behavior<Child.Message>.setup { context in
                Child.makeBehavior(instance: makeActorable(.init(underlying: context)))
            }
        )
        return Actor<Child>(ref: ref)
    }

    public func spawn<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> Child) throws -> Actor<Child> {
        let ref: ActorRef = try self._underlying.spawn(naming, of: Child.Message.self, Child.makeBehavior(instance: makeActorable()))
        return Actor<Child>(ref: ref)
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// For a detailed explanation of the both concepts refer to the `spawn` and `watch` documentation.
    ///
    /// - SeeAlso: `spawn`
    /// - SeeAlso: `watch`
    public func spawnWatch<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (Actor<Child>.Context) -> Child) throws -> Actor<Child> {
        let actor = try self.spawn(naming, makeActorable)
        return self.watch(actor)
    }

    public func spawnWatch<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> Child) throws -> Actor<Child> {
        let actor = try self.spawn(naming, makeActorable)
        return self.watch(actor)
    }
}

// TODO: public func stop() to stop myself.

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Timers

extension Actor.Context {
    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: Timers<A.Message> {
        self._underlying.timers
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Death Watch

extension Actor.Context {
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
    ///     let child = try context.watch(context.spawn("child", (behavior)))
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    @discardableResult
    public func watch<Act>(_ watchee: Actor<Act>, file: String = #file, line: UInt = #line) -> Actor<Act> { // TODO: fix signature, should the watchee
        _ = self._underlying.watch(watchee.ref, file: file, line: line)
        return watchee
    }

    internal func watch(_ watchee: AddressableActorRef, file: String = #file, line: UInt = #line) {
        self._underlying.watch(watchee, file: file, line: line)
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
    /// - Returns: the passed in watchee reference for easy chaining `e.g. context.unwatch(ref)`
    @discardableResult
    public func unwatch<Act>(_ watchee: Actor<Act>, file: String = #file, line: UInt = #line) -> Actor<Act> {
        _ = self._underlying.unwatch(watchee.ref, file: file, line: line)
        return watchee
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Suspending / Future inter-op

extension Actor.Context {
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
    public func awaitResult<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount = .effectivelyInfinite, _ continuation: @escaping (Result<AR.Value, Error>) throws -> Void) -> Behavior<Myself.Message> {
        asyncResult.withTimeout(after: timeout)._onComplete { [weak myCell = self.myself.ref._unsafeUnwrapCell] result in
            myCell?.sendSystemMessage(.resume(result.map { $0 }))
        }

        return Behavior<Myself.Message>.suspend(
            handler: { (res: Result<AR.Value, Error>) in
                try continuation(res)
                return .same
            }
        )
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
    public func awaitResultThrowing<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount = .effectivelyInfinite, _ continuation: @escaping (AR.Value) throws -> Void) -> Behavior<Myself.Message> {
        self.awaitResult(of: asyncResult, timeout: timeout) { result in
            switch result {
            case .success(let res): return try continuation(res)
            case .failure(let error): throw error
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: onResultAsync

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
    public func onResultAsync<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount, _ continuation: @escaping (Result<AR.Value, Error>) throws -> Void) {
        self._underlying.onResultAsync(of: asyncResult, timeout: timeout) { result in
            try continuation(result)
            return .same
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
    public func onResultAsyncThrowing<AR: AsyncResult>(of asyncResult: AR, timeout: TimeAmount, _ continuation: @escaping (AR.Value) throws -> Void) {
        self._underlying.onResultAsyncThrowing(of: asyncResult, timeout: timeout) { result in
            try continuation(result)
            return .same
        }
    }
}
