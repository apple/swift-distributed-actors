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

import Logging

/// The `_ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// - Warning:
///   - It MUST only ever be accessed from its own Actor. It is fine though to close over it in the actors behaviours.
///   - It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).
public class _ActorContext<Message: Codable> /* TODO(sendable): NOTSendable*/ {
    public typealias Myself = _ActorRef<Message>

    /// Returns `ClusterSystem` which this context belongs to.
    public var system: ClusterSystem {
        _undefined()
    }

    /// Uniquely identifies this actor in the cluster.
    public var id: ActorID {
        _undefined()
    }

    /// Local path under which this actor resides within the actor tree.
    public var path: ActorPath {
        _undefined()
    }

    /// Name of this actor.
    ///
    /// The `name` is the last segment of the Actor's `path`.
    ///
    /// Special characters like `$` are reserved for internal use of the `ClusterSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `_ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public var name: String {
        _undefined()
    }

    /// The actor reference to _this_ actor.
    ///
    /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
    /// as such would not be the "same" actor anymore.
    // Implementation note:
    // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
    // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
    // to get developers into the right mindset.
    public var myself: _ActorRef<Message> {
        _undefined()
    }

    /// Provides context metadata aware `Logger`
    public var log: Logger {
        get {
            _undefined()
        }
        set { // has to become settable
            fatalError()
        }
    }

    /// `_Props` which were used when spawning this actor.
    public var props: _Props {
        _undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: _BehaviorTimers

    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: _BehaviorTimers<Message> {
        _undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internal _stop capability (without returning _Behavior.stop) for Actorables

    /// Allows setting the "next" behavior externally.
    ///
    /// Exists solely for Actorables, should not be used in the Behavior style API.
    /// MUST be invoked from inside the actor (i.e. not concurrently).
    internal func _forceStop() {
        _undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch

    @discardableResult
    public func watch<Watchee>(
        _ watchee: Watchee,
        with terminationMessage: Message? = nil,
        file: String = #filePath, line: UInt = #line
    ) -> Watchee where Watchee: _DeathWatchable {
        _undefined()
    }

    @discardableResult
    public func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #filePath, line: UInt = #line
    ) -> Watchee where Watchee: _DeathWatchable {
        _undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Child actor management

    @discardableResult
    public func _spawn<M>(
        _ naming: _ActorNaming,
        of type: M.Type = M.self,
        props: _Props = _Props(),
        file: String = #filePath, line: UInt = #line,
        _ behavior: _Behavior<M>
    ) throws -> _ActorRef<M>
        where M: Codable
    {
        _undefined()
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// For a detailed explanation of the both concepts refer to the `spawn` and `watch` documentation.
    ///
    /// - SeeAlso: `spawn`
    /// - SeeAlso: `watch`
    @discardableResult
    public func _spawnWatch<M>(
        _ naming: _ActorNaming,
        of type: M.Type = M.self,
        props: _Props = _Props(),
        file: String = #filePath, line: UInt = #line,
        _ behavior: _Behavior<M>
    ) throws -> _ActorRef<M>
        where M: Codable
    {
        _undefined()
    }

    /// Container of spawned child actors.
    ///
    /// Allows obtaining references to previously spawned actors by their name.
    /// For less dynamic scenarios it is recommended to keep actors refs in your own collection types or as values in your behavior,
    /// since looking up actors by name has an inherent seek cost associated with it.
    public var children: _Children {
        get {
            _undefined()
        }
        set {
            fatalError()
        }
    }

    /// Stop a child actor identified by the passed in actor ref.
    ///
    /// **Logs Warnings** when the actor could have been a child of this actor, however it is currently not present in its children container,
    ///    it means that either we attempted to stop an actor "twice" (which is a no-op) or that we are a re-incarnation under the same
    ///    parent math of some actor, and we attempted to stop a non existing child, which also is a no-op however indicates an issue
    ///    in the logic of our actor.
    ///
    /// - Throws: an `_ActorContextError` when an actor ref is passed in that is NOT a child of the current actor.
    ///           An actor may not terminate another's child actors. Attempting to stop `myself` using this method will
    ///           also throw, as the proper way of stopping oneself is returning a `_Behavior.stop`.
    public func stop<M>(child ref: _ActorRef<M>) throws where M: Codable {
        return _undefined()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Suspension Mechanisms

    /// Not intended to be used by end users.
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
    internal func makeAsynchronousCallback<T>(file: String = #filePath, line: UInt = #line, _ callback: @escaping (T) throws -> Void) -> AsynchronousCallback<T> {
        AsynchronousCallback(callback: callback) { [weak selfRef = self.myself._unsafeUnwrapCell] in
            selfRef?.sendClosure(file: file, line: line, $0)
        }
    }

    /// Not intended to be used by end users.
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
    internal func makeAsynchronousCallback<T>(for type: T.Type, file: String = #filePath, line: UInt = #line, callback: @escaping (T) throws -> Void) -> AsynchronousCallback<T> {
        AsynchronousCallback(callback: callback) { [weak selfRef = self.myself._unsafeUnwrapCell] in
            selfRef?.sendClosure(file: file, line: line, $0)
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
    ///   - _AsyncResult: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the _AsyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `_AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `_AsyncResult` completes
    internal func awaitResult<AR: _AsyncResult>(of _AsyncResult: AR, timeout: Duration, _ continuation: @escaping (Result<AR.Value, Error>) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _AsyncResult.withTimeout(after: timeout)._onComplete { [weak selfRef = self.myself._unsafeUnwrapCell] result in
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
    ///   - _AsyncResult: result of an asynchronous operation the actor is waiting for
    ///   - timeout: time after which the _AsyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `_AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    /// - Returns: a behavior that causes the actor to suspend until the `_AsyncResult` completes
    internal func awaitResultThrowing<AR: _AsyncResult>(
        of _AsyncResult: AR,
        timeout: Duration,
        _ continuation: @escaping (AR.Value) throws -> _Behavior<Message>
    ) -> _Behavior<Message> {
        self.awaitResult(of: _AsyncResult, timeout: timeout) { result in
            switch result {
            case .success(let res): return try continuation(res)
            case .failure(let error): throw error
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
    ///   - timeout: time after which the _AsyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `_AsyncResult` completes.
    ///     It is safe to access and modify actor state from here.
    internal func onResultAsync<AR: _AsyncResult>(of _AsyncResult: AR, timeout: Duration, file: String = #filePath, line: UInt = #line, _ continuation: @escaping (Result<AR.Value, Error>) throws -> _Behavior<Message>) {
        let asyncCallback = self.makeAsynchronousCallback(for: Result<AR.Value, Error>.self, file: file, line: line) {
            let nextBehavior = try continuation($0)
            let shell = self._downcastUnsafe
            shell.behavior = try shell.behavior.canonicalize(shell, next: nextBehavior)
        }

        _AsyncResult.withTimeout(after: timeout)._onComplete { res in
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
    ///   - timeout: time after which the _AsyncResult will be failed if it does not complete
    ///   - continuation: continuation to run after `_AsyncResult` completes. It is safe to access
    ///                   and modify actor state from here.
    internal func onResultAsyncThrowing<AR: _AsyncResult>(of _AsyncResult: AR, timeout: Duration, _ continuation: @escaping (AR.Value) throws -> _Behavior<Message>) {
        self.onResultAsync(of: _AsyncResult, timeout: timeout) { res in
            switch res {
            case .success(let value): return try continuation(value)
            case .failure(let error): throw error
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------

    // MARK: Message Adapters & Sub-Receive

    /// Adapts this `_ActorRef` to accept messages of another type by applying the conversion
    /// function. There can only be one adapter defined per type. Creating a new adapter will
    /// replace an existing adapter.
    ///
    /// The returned `_ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `_ActorRef` terminates as well.
    ///
    /// ### Dropping messages
    /// It is possible to return `nil` as the result of an adaptation, which results in the message
    /// being silently dropped. This can be useful when not all messages `From` have a valid representation in
    /// `Message`, or if not all `From` messages are of interest for this particular actor.
    public final func messageAdapter<From>(_ adapt: @escaping (From) -> Message?) -> _ActorRef<From>
        where From: Codable
    {
        return self.messageAdapter(from: From.self, adapt: adapt)
    }

    /// Adapts this `_ActorRef` to accept messages of another type by applying the conversion
    /// function. There can only be one adapter defined per type. Creating a new adapter will
    /// replace an existing adapter.
    ///
    /// The returned `_ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `_ActorRef` terminates as well.
    ///
    /// ### Dropping messages
    /// It is possible to return `nil` as the result of an adaptation, which results in the message
    /// being silently dropped. This can be useful when not all messages `From` have a valid representation in
    /// `Message`, or if not all `From` messages are of interest for this particular actor.
    public func messageAdapter<From>(from type: From.Type, adapt: @escaping (From) -> Message?) -> _ActorRef<From>
        where From: Codable
    {
        return _undefined()
    }

    /// Creates an `_ActorRef` that can receive messages of the specified type, but executed in the same
    /// context as the actor owning it, meaning that it is safe to close over mutable state internal to the
    /// surrounding actor and modify it.
    ///
    /// The returned `_ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `_ActorRef` terminates as well.
    ///
    /// There can only be one `subReceive` per `_SubReceiveId`. When installing a new `subReceive`
    /// with an existing `_SubReceiveId`, it replaces the old one. All references will remain valid and point to
    /// the new behavior.
    public func subReceive<SubMessage>(_: _SubReceiveId<SubMessage>, _: SubMessage.Type, _: @escaping (SubMessage) throws -> Void) -> _ActorRef<SubMessage>
        where SubMessage: Codable
    {
        return _undefined()
    }

    /// Creates an `_ActorRef` that can receive messages of the specified type, but executed in the same
    /// context as the actor owning it, meaning that it is safe to close over mutable state internal to the
    /// surrounding actor and modify it.
    ///
    /// The returned `_ActorRef` can be watched and the lifetime is bound to that of the owning actor, meaning
    /// that when the owning actor terminates, this `_ActorRef` terminates as well.
    ///
    /// There can only be one `subReceive` per type. When installing a new `subReceive`
    /// with an existing type, it replaces the old one. All references will remain valid and point to
    /// the new behavior.
    public func subReceive<SubMessage>(_ type: SubMessage.Type, _ closure: @escaping (SubMessage) throws -> Void) -> _ActorRef<SubMessage> {
        self.subReceive(_SubReceiveId(type), type, closure)
    }

    @usableFromInline
    func subReceive(identifiedBy identifier: _AnySubReceiveId) -> ((SubMessageCarry) throws -> _Behavior<Message>)? {
        _undefined()
    }
}

/// Used to identify a `subReceive`.
// TODO(distributed): sub-receives will be removed shortly, thanks to actors in the language there are other ways to solve this.
public struct _SubReceiveId<SubMessage>: Hashable, Equatable {
    public let id: String

    public init(_: SubMessage.Type) {
        let typeName = String(reflecting: SubMessage.self)
            .replacingOccurrences(of: "()", with: "Void")
            .replacingOccurrences(of: " ", with: "")
        self.id = typeName
    }

    public init(_ type: SubMessage.Type = SubMessage.self, id: String) {
        self.id = id
            .replacingOccurrences(of: "()", with: "Void")
            .replacingOccurrences(of: " ", with: "")
    }
}

extension _SubReceiveId: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self.init(id: value)
    }
}

// TODO(distributed): sub-receives will be removed shortly, thanks to actors in the language there are other ways to solve this.
public struct _AnySubReceiveId: Hashable, Equatable {
    let underlying: AnyHashable

    init<SubMessage>(_ id: _SubReceiveId<SubMessage>) {
        self.underlying = AnyHashable(id)
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
