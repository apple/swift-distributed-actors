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

/// A `_Behavior` is what executes when an `Actor` handles messages.
///
/// The most important behavior is `_Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public struct _Behavior<Message: Codable>: @unchecked Sendable {
    let underlying: __Behavior<Message>

    init(underlying: __Behavior<Message>) {
        self.underlying = underlying
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Message Handling

extension _Behavior {
    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    ///
    /// - SeeAlso: `receiveMessage` convenience behavior for when you do not need to access the `ActorContext`.
    public static func receive(_ handle: @escaping (_ActorContext<Message>, Message) throws -> _Behavior<Message>) -> _Behavior {
        _Behavior(underlying: .receive(handle))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    ///
    /// - SeeAlso: `receive` convenience if you also need to access the `ActorContext`.
    public static func receiveMessage(_ handle: @escaping (Message) throws -> _Behavior<Message>) -> _Behavior {
        _Behavior(underlying: .receiveMessage(handle))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Async Message handling

extension _Behavior {
    func receiveAsync0(
        _ recv: @Sendable @escaping (Message) async throws -> _Behavior<Message>,
        context: _ActorContext<Message>,
        message: Message
    ) -> _Behavior<Message> {
        let loop = context.system._eventLoopGroup.next()
        let promise = loop.makePromise(of: _Behavior<Message>.self)

        // TODO: pretty sub-optimal, but we'll flatten this all out eventually
        Task {
            do {
                let next = try await recv(message)
                promise.succeed(next)
            } catch {
                promise.fail(error)
            }
        }

        return context.awaitResultThrowing(of: promise.futureResult, timeout: .effectivelyInfinite) { next in
            // become the "next" behavior, realistically with 'distributed actor' this is always '.same'
            next
        }
    }

    @usableFromInline
    func receiveAsync(
        _ recv: @Sendable @escaping (_ActorContext<Message>, Message) async throws -> _Behavior<Message>,
        _ message: Message
    ) -> _Behavior<Message> {
        .setup { context in
            receiveAsync0({ message in
                try await recv(context, message)
            }, context: context, message: message)
        }
    }

    @usableFromInline
    func receiveMessageAsync(
        _ recv: @Sendable @escaping (Message) async throws -> _Behavior<Message>,
        _ message: Message
    ) -> _Behavior<Message> {
        .setup { context in
            receiveAsync0(recv, context: context, message: message)
        }
    }

    func receiveSignalAsync0(
        _ handleSignal: @Sendable @escaping (_ActorContext<Message>, _Signal) async throws -> _Behavior<Message>,
        context: _ActorContext<Message>,
        signal: _Signal
    ) -> _Behavior<Message> {
        .setup { context in
            let loop = context.system._eventLoopGroup.next()
            let promise = loop.makePromise(of: _Behavior<Message>.self)

            // TODO: pretty sub-optimal, but we'll flatten this all out eventually
            Task {
                do {
                    let next = try await handleSignal(context, signal)
                    promise.succeed(next)
                } catch {
                    promise.fail(error)
                }
            }

            return context.awaitResultThrowing(of: promise.futureResult, timeout: .effectivelyInfinite) { next in
                // become the "next" behavior, realistically with 'distributed actor' this is always '.same'
                next
            }
        }
    }

    @usableFromInline
    func receiveSignalAsync(
        context: _ActorContext<Message>,
        signal: _Signal,
        handleSignal: @escaping @Sendable (
            _ActorContext<Message>,
            _Signal
        ) async throws -> _Behavior<Message>
    ) -> _Behavior<Message> {
        .setup { context in
            receiveSignalAsync0(handleSignal, context: context, signal: signal)
        }
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    ///
    /// The function is asynchronous and is allowed to suspend.
    ///
    /// WARNING: Use this ONLY with 'distributed actor' which will guarantee the actor hops are correct.
    ///
    /// - SeeAlso: `_receiveMessageAsync` convenience behavior for when you do not need to access the `ActorContext`.
    public static func _receiveAsync(_ handle: @Sendable @escaping (_ActorContext<Message>, Message) async throws -> _Behavior<Message>) -> _Behavior {
        _Behavior(underlying: .receiveAsync(handle))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    ///
    ///
    /// The function is asynchronous and is allowed to suspend.
    ///
    /// WARNING: Use this ONLY with 'distributed actor' which will guarantee the actor hops are correct.
    ///
    /// - SeeAlso: `_receiveAsync` convenience if you also need to access the `ActorContext`.
    public static func _receiveMessageAsync(_ handle: @Sendable @escaping (Message) async throws -> _Behavior<Message>) -> _Behavior {
        _Behavior(underlying: .receiveMessageAsync(handle))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Most often used next-Behaviors

extension _Behavior {
    /// Defines that the "same" behavior should remain in use for handling the next message.
    ///
    /// Note: prefer returning `.same` rather than "the same instance" of a behavior, as `.same` is internally optimized
    /// to avoid allocating and swapping behavior states when no changes are needed to be made.
    public static var same: _Behavior<Message> {
        _Behavior(underlying: .same)
    }

    /// Causes a message to be assumed unhandled by the runtime.
    /// Unhandled messages are logged by default, and other behaviors may use this information to implement `apply1.orElse(apply2)` style logic.
    // TODO: and their logging rate should be configurable
    public static var unhandled: _Behavior<Message> {
        _Behavior(underlying: .unhandled)
    }

    /// Ignore an incoming message.
    ///
    /// Ignoring a message differs from handling it with "unhandled" since the later can be acted upon by another behavior,
    /// such as "orElse" which can be used for behavior composition. `ignore` on the other hand does "consume" the message,
    /// in the sense that we did handle it, however simply chose to ignore it.
    ///
    /// Returning `ignore` implies remaining the same behavior, the same way as would returning `.same`.
    public static var ignore: _Behavior<Message> {
        _Behavior(underlying: .ignore)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Behaviors

extension _Behavior {
    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// #### Example usage
    /// ```
    /// .setup { context in
    ///     // e.g. spawn worker on startup:
    ///     let worker = try context._spawn("worker", (workerBehavior))
    ///
    ///     // it is safe to mutate actor "enclosed" state created e.g. during setup:
    ///     var workRequestsCounter = 0
    ///
    ///     return .receiveMessage { workRequest in
    ///          workRequestsCounter += 1
    ///         // do actual work...
    ///     }
    /// }
    /// ```
    ///
    /// This can be used to obtain the context, logger or perform actions right when the actor starts
    /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
    public static func setup(_ onStart: @escaping (_ActorContext<Message>) throws -> _Behavior<Message>) -> _Behavior {
        _Behavior(underlying: .setup(onStart))
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. The last assigned behavior
    /// will be used to handle the `_PostStop` signal after the actor has stopped. This allows users to use
    /// the same signal handler (chain) to process all events.
    ///
    /// - SeeAlso: `stop(_:)` and `stop(postStop:) overloads for adding cleanup code to be executed upon receipt of _PostStop signal.
    public static var stop: _Behavior<Message> {
        _Behavior.stop(postStop: nil, reason: .stopMyself)
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. This is a convenience overload that
    /// allows users to specify a closure that will only be called on receipt of `_PostStop` and therefore does not
    /// need to get the signal passed in. It also does not need to return a new behavior, as the actor is already stopping.
    public static func stop(_ postStop: @escaping (_ActorContext<Message>) throws -> Void) -> _Behavior<Message> {
        _Behavior.stop(
            postStop: _Behavior.receiveSignal { context, signal in
                if signal is _Signals._PostStop {
                    try postStop(context)
                }
                return .stop // will be ignored
            },
            reason: .stopMyself
        )
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. If a `postStop` behavior is
    /// set, it will be used to handle the `_PostStop` signal after the actor has stopped. Otherwise the last
    /// assigned behavior will be used. This allows users to use the same signal handler (chain) to process
    /// all events.
    public static func stop(postStop: _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .stop(postStop: postStop, reason: .stopMyself))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _Behavior Combinators

extension _Behavior {
    /// Creates a new _Behavior which on an incoming message will first execute the first (current) behavior,
    /// and if it returns `.unhandled` applies the alternative behavior passed in here.
    ///
    /// If the alternative behavior contains a `.setup` or other deferred behavior, it will be canonicalized on its first execution // TODO: make a test for it
    public func orElse(_ alternativeBehavior: _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .orElse(first: self, second: alternativeBehavior))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Signal receiving behaviors

extension _Behavior {
    /// Allows reacting to `Signal`s, such as lifecycle events.
    ///
    /// Note that this behavior _adds_ the ability to handle signals in addition to an existing message handling behavior
    /// (e.g. ``receive`) rather than replacing it.
    ///
    /// #### Example usage
    /// ```
    /// let withSignalHandling = behavior.receiveSignal { context, signal in
    ///     guard let terminated = signal as? Signals.Terminated else {
    ///         return .unhandled
    ///     }
    ///     if terminated.id.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .same
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSpecificSignal` for convenience version of this behavior, simplifying handling a single type of `Signal`.
    public func receiveSignal(_ handle: @escaping (_ActorContext<Message>, _Signal) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(
            underlying: .signalHandling(
                handleMessage: self,
                handleSignal: handle
            )
        )
    }

    public func _receiveSignalAsync(
        _ handle: @escaping @Sendable (_ActorContext<Message>, _Signal) async throws -> _Behavior<Message>
    ) -> _Behavior<Message> {
        _Behavior(
            underlying: .signalHandlingAsync(
                handleMessage: self,
                handleSignal: handle
            )
        )
    }

    /// Allows reacting to `Signal`s, such as lifecycle events.
    ///
    /// Note that this behavior _adds_ the ability to handle signals in addition to an existing message handling behavior
    /// (e.g. ``receive`) rather than replacing it.
    ///
    /// #### Example usage
    /// ```
    /// let withSignalHandling = behavior.receiveSignal { context, signal in
    ///     guard let terminated = signal as? Signals.Terminated else {
    ///         return .unhandled
    ///     }
    ///     if terminated.id.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSpecificSignal` for convenience version of this behavior, simplifying handling a single type of `Signal`.
    public static func receiveSignal(_ handle: @escaping (_ActorContext<Message>, _Signal) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(
            underlying: .signalHandling(
                handleMessage: .unhandled,
                handleSignal: handle
            )
        )
    }

    /// Convenience function similar to `_Behavior.receiveSignal` however allowing for easier handling of a specific signal type, e.g.:
    ///
    /// #### Example usage
    /// ```
    /// let withSignalHandling = behavior.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
    ///     if terminated.id.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSignal` which allows receiving multiple types of signals.
    public func receiveSpecificSignal<SpecificSignal: _Signal>(_: SpecificSignal.Type, _ handle: @escaping (_ActorContext<Message>, SpecificSignal) throws -> _Behavior<Message>) -> _Behavior<Message> {
        // TODO: better type printout so we know we only handle SpecificSignal with this one
        self.receiveSignal { context, signal in
            switch signal {
            case let matchingSignal as SpecificSignal:
                return try handle(context, matchingSignal)
            default:
                return .unhandled
            }
        }
    }

    /// Convenience function similar to `_Behavior.receiveSignal` however allowing for easier handling of a specific signal type, e.g.:
    ///
    /// #### Example usage
    /// ```
    /// return .receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
    ///     if terminated.id.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSignal` which allows receiving multiple types of signals.
    public static func receiveSpecificSignal<SpecificSignal: _Signal>(_: SpecificSignal.Type, _ handle: @escaping (_ActorContext<Message>, SpecificSignal) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(
            underlying: .signalHandling(
                handleMessage: .unhandled,
                handleSignal: { context, signal in
                    switch signal {
                    case let matchingSignal as SpecificSignal:
                        return try handle(context, matchingSignal)
                    default:
                        return .unhandled
                    }
                }
            )
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal behavior creators

extension _Behavior {
    /// Allows handling signals such as termination or lifecycle events.
    @usableFromInline
    internal static func signalHandling(handleMessage: _Behavior<Message>, handleSignal: @escaping (_ActorContext<Message>, _Signal) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .signalHandling(handleMessage: handleMessage, handleSignal: handleSignal))
    }

    /// Allows handling signals such as termination or lifecycle events.
    @usableFromInline
    internal static func signalHandlingAsync(
        handleMessage: _Behavior<Message>,
        handleSignal: @escaping @Sendable (_ActorContext<Message>, _Signal) async throws -> _Behavior<Message>
    ) -> _Behavior<Message> {
        _Behavior(underlying: .signalHandlingAsync(handleMessage: handleMessage, handleSignal: handleSignal))
    }

    /// Causes an actor to go into suspended state.
    ///
    /// MUST be canonicalized (to .suspended before storing in an `ActorCell`, as thr suspend behavior CAN NOT handle messages.
    @usableFromInline
    internal static func suspend<T>(handler: @escaping (Result<T, Error>) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .suspend(handler: { result in
            try handler(result.map { $0 as! T }) // cast here is okay, as user APIs are typed, so we should always get a T
        }))
    }

    /// Represents a behavior in suspended state.
    ///
    /// A suspended actor will only react to system messages, until it is resumed.
    /// This usually happens when an async operation that caused the suspension
    /// is completed.
    @usableFromInline
    internal static func suspended(previousBehavior: _Behavior<Message>, handler: @escaping (Result<Any, Error>) throws -> _Behavior<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .suspended(previousBehavior: previousBehavior, handler: handler))
    }

    /// Creates internal representation of stopped behavior, see `stop(_:)` for public api.
    internal static func stop(postStop: _Behavior<Message>? = nil, reason: StopReason) -> _Behavior<Message> {
        _Behavior(underlying: .stop(postStop: postStop, reason: reason))
    }

    /// Internal way of expressing a failed actor, retains the behavior that has failed internally.
    ///
    /// - parameters
    ///   - error: cause of the actor's failing.
    internal func fail(cause: _Supervision.Failure) -> _Behavior<Message> {
        _Behavior(underlying: __Behavior<Message>.failed(behavior: self, cause: cause))
    }
}

internal enum __Behavior<Message: Codable> {
    case setup(_ onStart: (_ActorContext<Message>) throws -> _Behavior<Message>)

    case receive(_ handle: (_ActorContext<Message>, Message) throws -> _Behavior<Message>)
    case receiveAsync(_ handle: @Sendable (_ActorContext<Message>, Message) async throws -> _Behavior<Message>)

    case receiveMessage(_ handle: (Message) throws -> _Behavior<Message>)
    case receiveMessageAsync(_ handle: @Sendable (Message) async throws -> _Behavior<Message>)

    indirect case stop(postStop: _Behavior<Message>?, reason: StopReason)
    indirect case failed(behavior: _Behavior<Message>, cause: _Supervision.Failure)

    indirect case signalHandling(
        handleMessage: _Behavior<Message>,
        handleSignal: (_ActorContext<Message>, _Signal) throws -> _Behavior<Message>
    )
    indirect case signalHandlingAsync(
        handleMessage: _Behavior<Message>,
        handleSignal: @Sendable (_ActorContext<Message>, _Signal) async throws -> _Behavior<Message>
    )
    case same
    case ignore
    case unhandled

    indirect case intercept(behavior: _Behavior<Message>, with: _Interceptor<Message>) // TODO: for printing it would be nicer to have "supervised" here, though, modeling wise it is exactly an intercept

    indirect case orElse(first: _Behavior<Message>, second: _Behavior<Message>)

    case suspend(handler: (Result<Any, Error>) throws -> _Behavior<Message>)
    indirect case suspended(previousBehavior: _Behavior<Message>, handler: (Result<Any, Error>) throws -> _Behavior<Message>)
}

internal enum StopReason {
    /// the actor decided to stop and returned _Behavior.stop
    case stopMyself
    /// a stop was requested by the parent, i.e. `context.stop(child:)`
    case stopByParent
    /// the actor experienced a failure that was not handled by supervision
    case failure(_Supervision.Failure)
}

enum IllegalBehaviorError<Message: Codable>: Error {
    /// Some behaviors, like `.same` and `.unhandled` are not allowed to be used as initial behaviors.
    /// See their individual documentation for the rationale why that is so.
    case notAllowedAsInitial(_ behavior: _Behavior<Message>)

    /// Too deeply nested deferred behaviors (such a .setup) are not supported,
    /// and are often an indication of programming errors - e.g. infinitely infinitely
    /// growing behavior depth may be a mistake of accidentally needlessly wrapping behaviors with decorators they already contained.
    ///
    /// While technically it would be possible to support very very deep behaviors, in practice those are rare and Swift Distributed Actors
    /// currently opts to eagerly fail for those situations. If you have a legitimate need for such deeply nested deferred behaviors,
    /// please do not hesitate to open a ticket.
    case tooDeeplyNestedBehavior(reached: _Behavior<Message>, depth: Int)

    /// Not all behavior transitions are legal and can't be prevented statically.
    /// Example:
    /// Returning a `.same` directly from within a `.setup` like so: `.setup { _ in return .same }`is treated as illegal,
    /// as it has a high potential for resulting in an eagerly infinitely looping during behavior canonicalization.
    /// If such behavior is indeed what you want, you can return the behavior containing the setup rather than the `.same` marker.
    case illegalTransition(from: _Behavior<Message>, to: _Behavior<Message>)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Intercepting Messages

extension _Behavior {
    /// Intercepts all incoming messages and signals, allowing to transform them before they are delivered to the wrapped behavior.
    // TODO: more docs
    public static func intercept(behavior: _Behavior<Message>, with interceptor: _Interceptor<Message>) -> _Behavior<Message> {
        _Behavior(underlying: .intercept(behavior: behavior, with: interceptor))
    }
}

/// Used in combination with `_Behavior.intercept` to intercept messages and signals delivered to a behavior.
open class _Interceptor<Message: Codable> {
    public init() {}

    @inlinable
    open func interceptMessage(target: _Behavior<Message>, context: _ActorContext<Message>, message: Message) throws -> _Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        try target.interpretMessage(context: context, message: message)
    }

    @inlinable
    open func interceptSignal(target: _Behavior<Message>, context: _ActorContext<Message>, signal: _Signal) throws -> _Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        try target.interpretSignal(context: context, signal: signal)
    }

    @inlinable
    open func isSame(as other: _Interceptor<Message>) -> Bool {
        self === other
    }
}

extension _Interceptor {
    static func handleMessage(context: _ActorContext<Message>, behavior: _Behavior<Message>, interceptor: _Interceptor<Message>, message: Message) throws -> _Behavior<Message> {
        let next = try interceptor.interceptMessage(target: behavior, context: context, message: message)

        return try _Interceptor.deduplicate(context: context, behavior: next, interceptor: interceptor)
    }

    static func deduplicate(context: _ActorContext<Message>, behavior: _Behavior<Message>, interceptor: _Interceptor<Message>) throws -> _Behavior<Message> {
        func deduplicate0(_ behavior: _Behavior<Message>) -> _Behavior<Message> {
            let hasDuplicatedIntercept = behavior.existsInStack { b in
                switch b.underlying {
                case .intercept(_, let otherInterceptor): return interceptor.isSame(as: otherInterceptor)
                default: return false
                }
            }

            if hasDuplicatedIntercept {
                return behavior
            } else {
                return .intercept(behavior: behavior, with: interceptor)
            }
        }

        let started = try behavior.start(context: context)

        if case .stop(.some(let postStop), let reason) = started.underlying {
            return .stop(postStop: deduplicate0(postStop), reason: reason)
        } else if started.isUnhandled || started.isSame || started.isTerminal || started.isSuspend {
            return started
        } else {
            return deduplicate0(started)
        }
    }
}

// MARK: _Behavior interpretation

/// Offers the capability to interpret messages and signals
extension _Behavior {
    /// Interpret the passed in message.
    ///
    /// Note: The returned behavior MUST be `_Behavior.canonicalize`-ed in the vast majority of cases.
    // Implementation note: We don't do so here automatically in order to keep interpretations transparent and testable.
    public func interpretMessage(context: _ActorContext<Message>, message: Message, file: StaticString = #file, line: UInt = #line) throws -> _Behavior<Message> {
        switch self.underlying {
        case .receiveMessage(let recv): return try recv(message)
        case .receiveMessageAsync(let recv): return self.receiveMessageAsync(recv, message)

        case .receive(let recv): return try recv(context, message)
        case .receiveAsync(let recv): return self.receiveAsync(recv, message)

        case .signalHandling(let recvMsg, _): return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests
        case .signalHandlingAsync(let recvMsg, _): return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests

        case .intercept(let inner, let interceptor): return try _Interceptor.handleMessage(context: context, behavior: inner, interceptor: interceptor, message: message)
        case .orElse(let first, let second): return try self.interpretOrElse(context: context, first: first, orElse: second, message: message, file: file, line: line)

        // illegal to attempt interpreting at the following behaviors (e.g. should have been canonicalized before):
        case .same: fatalError("Illegal attempt to interpret message with .same behavior! _Behavior should have been canonicalized. This is a bug, please open a ticket.", file: file, line: line)
        case .ignore: fatalError("Illegal attempt to interpret message with .ignore behavior! _Behavior should have been canonicalized before interpreting; This is a bug, please open a ticket.", file: file, line: line)
        case .unhandled: fatalError("Illegal attempt to interpret message with .unhandled behavior! _Behavior should have been canonicalized before interpreting; This is a bug, please open a ticket.", file: file, line: line)

        case .setup:
            return fatalErrorBacktrace("""
            Illegal attempt to interpret message with .setup behavior! Behaviors MUST be canonicalized before interpreting. This is a bug, please open a ticket. 
              System: \(context.system)
              Address: \(context.id.detailedDescription)
              Message: \(message): \(type(of: message))
              _Behavior: \(self)
            """, file: file, line: line)

        case .stop:
            return .unhandled
        case .failed:
            return .unhandled

        case .suspend:
            fatalError("Illegal to attempt to interpret message with .suspend behavior! _Behavior should have been canonicalized. This is a bug, please open a ticket.", file: file, line: line)
        case .suspended:
            fatalError("""
            No message should ever be delivered to a .suspended behavior!
              Message: \(message)
              Actor: \(context)
              This is a bug, please open a ticket.
            """, file: file, line: line)
        }
    }

    /// Attempts interpreting signal using the current behavior, or returns `_Behavior.unhandled` if no `_Behavior.signalHandling` was found.
    public func interpretSignal(context: _ActorContext<Message>, signal: _Signal) throws -> _Behavior<Message> {
        // This switch does not use a `default:` clause on purpose!
        // This is to enforce having to consider consider how a signal should be interpreted if a new behavior case is added.
        switch self.underlying {
        case .stop(let postStop, let reason):
            if let postStop = postStop {
                return try .stop(postStop: postStop.interpretSignal(context: context, signal: signal), reason: reason)
            } else {
                return .same
            }

        case .failed(let behavior, let cause):
            return try _Behavior(underlying: .failed(behavior: behavior.interpretSignal(context: context, signal: signal), cause: cause))

        case .signalHandling(_, let handleSignal):
            return try handleSignal(context, signal)
        case .signalHandlingAsync(_, let receiveSignalAsync):
            return self.receiveSignalAsync(context: context, signal: signal, handleSignal: receiveSignalAsync)

        case .orElse(let first, let second):
            let maybeHandled = try first.interpretSignal(context: context, signal: signal)
            if maybeHandled.isUnhandled {
                return try second.interpretSignal(context: context, signal: signal)
            } else {
                return maybeHandled
            }
        case .intercept(let behavior, let interceptor):
            return try interceptor.interceptSignal(target: behavior, context: context, signal: signal) // TODO: do we need to try?
        case .suspended(let previous, let handler):
            let nextBehavior = try previous.interpretSignal(context: context, signal: signal)
            if nextBehavior.isTerminal {
                return nextBehavior
            } else {
                return try .suspended(previousBehavior: previous.canonicalize(context, next: nextBehavior), handler: handler)
            }

        case .receiveMessage, .receive:
            return .unhandled
        case .receiveMessageAsync, .receiveAsync:
            return .unhandled
        case .setup:
            return .unhandled

        case .same:
            return .unhandled
        case .ignore:
            return .unhandled
        case .unhandled:
            return .unhandled

        case .suspend:
            return .unhandled
        }
    }
}

// MARK: Internal tools to work with Behaviors

/// Internal operations for behavior manipulation
extension _Behavior {
    internal func interpretOrElse(
        context: _ActorContext<Message>,
        first: _Behavior<Message>, orElse second: _Behavior<Message>, message: Message,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> _Behavior<Message> {
        var nextBehavior = try first.interpretMessage(context: context, message: message, file: file, line: line)
        if nextBehavior.isUnhandled {
            nextBehavior = try second.interpretMessage(context: context, message: message, file: file, line: line)
        }
        return nextBehavior
    }

    /// Applies `interpretMessage` to an iterator of messages, while canonicalizing the behavior after every reduction.
    internal func interpretMessages<Iterator: IteratorProtocol>(context: _ActorContext<Message>, messages: inout Iterator) throws -> _Behavior<Message> where Iterator.Element == Message {
        var currentBehavior: _Behavior<Message> = self
        while currentBehavior.isStillAlive {
            if let message = messages.next() {
                let nextBehavior = try currentBehavior.interpretMessage(context: context, message: message)
                currentBehavior = try currentBehavior.canonicalize(context, next: nextBehavior)
            } else {
                break
            }
        }

        return currentBehavior
    }

    /// Validate if a _Behavior is legal to be used as "initial" behavior (when an Actor is spawned),
    /// since certain behaviors do not make sense as initial behavior.
    internal func validateAsInitial() throws {
        switch self.underlying {
        case .same: throw IllegalBehaviorError.notAllowedAsInitial(self)
        case .unhandled: throw IllegalBehaviorError.notAllowedAsInitial(self)
        default: return ()
        }
    }

    /// Same as `validateAsInitial`, however useful in chaining expressions as it returns itself when the validation has passed successfully.
    internal func validatedAsInitial() throws -> _Behavior<Message> {
        try self.validateAsInitial()
        return self
    }

    internal func validateAsInitialFatal(file: String = #filePath, line: UInt = #line) {
        switch self.underlying {
        case .same, .unhandled: fatalError("Illegal initial behavior! Attempted to spawn(\(self)) at \(file):\(line)")
        default: return
        }
    }

    /// Shorthand for checking if the current behavior is a `.unhandled`
    internal var isUnhandled: Bool {
        switch self.underlying {
        case .unhandled: return true
        default: return false
        }
    }

    /// Shorthand for checking if the `_Behavior` is `.stop` or `.failed`.
    internal var isTerminal: Bool {
        switch self.underlying {
        case .stop, .failed: return true
        default: return false
        }
    }

    /// Shorthand for checking if the `_Behavior` is NOT `.stop` or `.failed`.
    internal var isStillAlive: Bool {
        !self.isTerminal
    }

    internal var isSuspend: Bool {
        switch self.underlying {
        case .suspend: return true
        default: return false
        }
    }

    internal var isSuspended: Bool {
        switch self.underlying {
        case .suspended: return true
        default: return false
        }
    }

    internal var isSame: Bool {
        switch self.underlying {
        case .same: return true
        default: return false
        }
    }

    internal var isSetup: Bool {
        switch self.underlying {
        case .setup: return true
        default: return false
        }
    }

    /// Returns `false` if canonicalizing behavior is known to not create a change in behavior.
    /// For example `.same` or semantically equivalent behaviors.
    internal var isChanging: Bool {
        switch self.underlying {
        case .same, .ignore, .unhandled: return false
        default: return true
        }
    }

    /// Ensure that the behavior is in "canonical form", i.e. that all setup behaviors are reduced (run)
    /// before storing the behavior. This process may trigger executing setup(onStart) behaviors.
    ///
    /// Warning: Remember that a first start (or re-start) of a behavior must be triggered using `_Behavior.start`
    ///          rather than just canonicalize since we want to recursively trigger
    ///
    /// - Throws: `IllegalBehaviorError.tooDeeplyNestedBehavior` when a too deeply nested behavior is found,
    ///           in order to avoid attempting to start an possibly infinitely deferred behavior.
    internal func canonicalize(_ context: _ActorContext<Message>, next: _Behavior<Message>) throws -> _Behavior<Message> {
        guard self.isStillAlive else {
            return self // ignore, we're already dead and cannot become any other behavior
        }

        // Note: on purpose not implemented as tail recursive function since tail-call elimination is not guaranteed
        let failAtDepth = context.system.settings.actor.maxBehaviorNestingDepth

        // TODO: what if already stopped or failed

        func canonicalize0(_ context: _ActorContext<Message>, base: _Behavior<Message>, next: _Behavior<Message>, depth: Int) throws -> _Behavior<Message> {
            let deeper = depth + 1
            guard depth < failAtDepth else {
                throw IllegalBehaviorError.tooDeeplyNestedBehavior(reached: next, depth: depth)
            }

            var canonical = next
            while true {
                switch canonical.underlying {
                case .setup(let onStart): canonical = try onStart(context)

                case .same where self.isSetup: throw IllegalBehaviorError.illegalTransition(from: self, to: next)
                case .same: return base
                case .ignore: return base
                case .unhandled: return base

                case .stop(.none, let reason): return .stop(postStop: base, reason: reason)
                case .stop(.some, _): return canonical
                case .failed: return canonical

                case .orElse(let first, let second):
                    let canonicalFirst = try canonicalize0(context, base: canonical, next: first, depth: deeper)
                    let canonicalSecond = try canonicalize0(context, base: canonical, next: second, depth: deeper)
                    return canonicalFirst.orElse(canonicalSecond)

                case .intercept(let inner, let interceptor):
                    let innerCanonicalized: _Behavior<Message> = try canonicalize0(context, base: inner, next: .same, depth: deeper)
                    return .intercept(behavior: innerCanonicalized, with: interceptor)

                case .signalHandling(let onMessage, let onSignal):
                    return .signalHandling(
                        handleMessage: try canonicalize0(context, base: canonical, next: onMessage, depth: deeper),
                        handleSignal: onSignal
                    )
                case .signalHandlingAsync(let onMessage, let onSignalAsync):
                    return .signalHandlingAsync(
                        handleMessage: try canonicalize0(context, base: canonical, next: onMessage, depth: deeper),
                        handleSignal: onSignalAsync
                    )

                case .suspend(let handler):
                    return .suspended(previousBehavior: base, handler: handler)
                case .suspended:
                    return canonical

                case .receive, .receiveMessage:
                    return canonical
                case .receiveAsync, .receiveMessageAsync:
                    return canonical
                }
            }
        }

        return try canonicalize0(context, base: self, next: next, depth: 0)
    }

    /// Starting a behavior means triggering all onStart actions of nested `.setup` calls.
    /// Interceptors are left in-place, and other behaviors remain unaffected.
    ///
    /// - Throws: `IllegalBehaviorError.tooDeeplyNestedBehavior` when a too deeply nested behavior is found,
    ///           in order to avoid attempting to start an possibly infinitely deferred behavior.
    // TODO: make not recursive perhaps since could blow up on large chain?
    internal func start(context: _ActorContext<Message>) throws -> _Behavior<Message> {
        let failAtDepth = context.system.settings.actor.maxBehaviorNestingDepth

        func start0(_ behavior: _Behavior<Message>, depth: Int) throws -> _Behavior<Message> {
            guard depth < failAtDepth else {
                throw IllegalBehaviorError.tooDeeplyNestedBehavior(reached: behavior, depth: depth)
            }

            // Note: DO NOT use `default:`, we always want to explicitly know when we add a behavior and add specific handling here.
            switch behavior.underlying {
            case .intercept(let inner, let interceptor):
                // FIXME: this should technically offload onto storage and then apply them again...
                return .intercept(behavior: try start0(inner, depth: depth + 1), with: interceptor)

            case .setup(let onStart):
                let started: _Behavior<Message> = try onStart(context)
                return try start0(started, depth: depth + 1)

            case .signalHandling(let onMessageBehavior, let onSignal):
                return .signalHandling(handleMessage: try start0(onMessageBehavior, depth: depth + 1), handleSignal: onSignal)

            case .orElse(let main, let fallback):
                return try start0(main, depth: depth + 1)
                    .orElse(start0(fallback, depth: depth + 1))

            case .suspended(let previousBehavior, _):
                return try start0(previousBehavior, depth: depth + 1)

            default: // TODO: remove the use of default: it is the devil </3
                return behavior
            }
        }

        return try start0(self, depth: 0)
    }

    /// Looks for a behavior in the stack that returns `true` for the passed in predicate.
    ///
    /// - Parameter predicate: used to check if any behavior in the stack has a specific property
    /// - Returns: `true` if a behavior exists that matches the predicate, `false` otherwise
    internal func existsInStack(_ predicate: (_Behavior<Message>) -> Bool) -> Bool {
        if predicate(self) {
            return true
        }

        switch self.underlying {
        case .intercept(let behavior, _): return behavior.existsInStack(predicate)
        case .orElse(let first, let second): return first.existsInStack(predicate) || second.existsInStack(predicate)
        case .stop(.some(let postStop), _): return postStop.existsInStack(predicate)
        default: return false
        }
    }
}

extension _Behavior: CustomStringConvertible {
    public var description: String {
        let fqcn = String(reflecting: _Behavior<Message>.self)
        return "\(fqcn).\(self.underlying)"
    }
}
