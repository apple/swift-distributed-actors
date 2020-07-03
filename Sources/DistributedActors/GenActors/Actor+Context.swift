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
// MARK: Actor<Act>.Context

extension Actor {
    /// `Context` of the `Actor`, exposing details and capabilities of the actor, such as spawning, starting timers and similar.
    ///
    /// - ***Warning**: MUST NOT be shared "outside" the actor, as it is only safe to access by the owning actor itself.
    ///
    /// The `Actor<Act>.Context` is the `Actorable` equivalent of `ActorContext<Message>`, which is designed to work with the low-level `Behavior` types.
    public struct Context {
        public typealias Message = Self.Myself.Message

        /// Only public to enable workarounds while all APIs gain Actor/Actorable style versions.
        public let _underlying: ActorContext<Act.Message>

        public init(underlying: ActorContext<Act.Message>) {
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
    public var myself: Actor<Act> {
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
// MARK: Actor<Act>.Context + Spawning

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

    /// - Warning: The way child actors are available today MAY CHANGE; See: https://github.com/apple/swift-distributed-actors/issues?q=is%3Aopen+is%3Aissue+label%3Aga%3Aactor-tree-removal
    ///
    /// Stop a child actor identified by the passed.
    ///
    /// **Logs Warnings** when the actor could have been a child of this actor, however it is currently not present in its children container,
    ///    it means that either we attempted to stop an actor "twice" (which is a no-op) or that we are a re-incarnation under the same
    ///    parent math of some actor, and we attempted to stop a non existing child, which also is a no-op however indicates an issue
    ///    in the logic of our actor.
    ///
    /// - Throws: an `ActorContextError` when an actor ref is passed in that is NOT a child of the current actor.
    ///           An actor may not terminate another's child actors. Attempting to stop `myself` using this method will
    ///           also throw, as the proper way of stopping oneself is returning a `Behavior.stop`.
    public func stop<Child>(child: Actor<Child>) throws where Child: Actorable {
        try self._underlying.stop(child: child.ref)
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<Act>.Context + Timers

extension Actor.Context {
    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: Timers<Act.Message> {
        self._underlying.timers
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<Act>.Context + Death Watch

extension Actor.Context: DeathWatchProtocol {
    @discardableResult
    public func watch<Watchee>(
        _ watchee: Watchee,
        with terminationMessage: Message? = nil,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DeathWatchable {
        self._underlying.watch(watchee, with: terminationMessage, file: file, line: line)
    }

    @discardableResult
    public func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DeathWatchable {
        self._underlying.unwatch(watchee, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<Act>.Context + Suspending / Future inter-op

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
