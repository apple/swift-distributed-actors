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

/// A `Behavior` is what executes when an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public struct Behavior<Message: ActorMessage>: @unchecked Sendable {
    @usableFromInline
    let underlying: _Behavior<Message>

    @usableFromInline
    init(underlying: _Behavior<Message>) {
        self.underlying = underlying
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Message Handling

extension Behavior {
    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    ///
    /// - SeeAlso: `receiveMessage` convenience behavior for when you do not need to access the `ActorContext`.
    public static func receive(_ handle: @escaping (ActorContext<Message>, Message) throws -> Behavior<Message>) -> Behavior {
        Behavior(underlying: .receive(handle))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    ///
    /// - SeeAlso: `receive` convenience if you also need to access the `ActorContext`.
    public static func receiveMessage(_ handle: @escaping (Message) throws -> Behavior<Message>) -> Behavior {
        Behavior(underlying: .receiveMessage(handle))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Async Message handling

extension Behavior {

    func receiveAsync0(_ recv: @Sendable @escaping (Message) async throws -> Behavior<Message>,
                       context: ActorContext<Message>,
                       message: Message) -> Behavior<Message> {
        let loop = context.system._eventLoopGroup.next()
        let promise = loop.makePromise(of: Behavior<Message>.self)

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

    func receiveAsync(_ recv: @Sendable @escaping (ActorContext<Message>, Message) async throws -> Behavior<Message>,
                      _ message: Message) -> Behavior<Message> {
        .setup { context in
            receiveAsync0({ message in
                try await recv(context, message)
            }, context: context, message: message)
        }
    }

    func receiveMessageAsync(_ recv: @Sendable @escaping (Message) async throws -> Behavior<Message>,
                             _ message: Message) -> Behavior<Message> {
        .setup { context in
            receiveAsync0(recv, context: context, message: message)
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
    public static func _receiveAsync(_ handle: @Sendable @escaping (ActorContext<Message>, Message) async throws -> Behavior<Message>) -> Behavior {
        Behavior(underlying: .receiveAsync(handle))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    ///
    ///
    /// The function is asynchronous and is allowed to suspend.
    ///
    /// WARNING: Use this ONLY with 'distributed actor' which will guarantee the actor hops are correct.
    ///
    /// - SeeAlso: `_receiveAsync` convenience if you also need to access the `ActorContext`.
    public static func _receiveMessageAsync(_ handle: @Sendable @escaping (Message) async throws -> Behavior<Message>) -> Behavior {
        Behavior(underlying: .receiveMessageAsync(handle))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Most often used next-Behaviors

extension Behavior {
    /// Defines that the "same" behavior should remain in use for handling the next message.
    ///
    /// Note: prefer returning `.same` rather than "the same instance" of a behavior, as `.same` is internally optimized
    /// to avoid allocating and swapping behavior states when no changes are needed to be made.
    public static var same: Behavior<Message> {
        Behavior(underlying: .same)
    }

    /// Causes a message to be assumed unhandled by the runtime.
    /// Unhandled messages are logged by default, and other behaviors may use this information to implement `apply1.orElse(apply2)` style logic.
    // TODO: and their logging rate should be configurable
    public static var unhandled: Behavior<Message> {
        Behavior(underlying: .unhandled)
    }

    /// Ignore an incoming message.
    ///
    /// Ignoring a message differs from handling it with "unhandled" since the later can be acted upon by another behavior,
    /// such as "orElse" which can be used for behavior composition. `ignore` on the other hand does "consume" the message,
    /// in the sense that we did handle it, however simply chose to ignore it.
    ///
    /// Returning `ignore` implies remaining the same behavior, the same way as would returning `.same`.
    public static var ignore: Behavior<Message> {
        Behavior(underlying: .ignore)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Behaviors

extension Behavior {
    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// #### Example usage
    /// ```
    /// .setup { context in
    ///     // e.g. spawn worker on startup:
    ///     let worker = try context.spawn("worker", (workerBehavior))
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
    public static func setup(_ onStart: @escaping (ActorContext<Message>) throws -> Behavior<Message>) -> Behavior {
        Behavior(underlying: .setup(onStart))
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. The last assigned behavior
    /// will be used to handle the `PostStop` signal after the actor has stopped. This allows users to use
    /// the same signal handler (chain) to process all events.
    ///
    /// - SeeAlso: `stop(_:)` and `stop(postStop:) overloads for adding cleanup code to be executed upon receipt of PostStop signal.
    public static var stop: Behavior<Message> {
        Behavior.stop(postStop: nil, reason: .stopMyself)
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. This is a convenience overload that
    /// allows users to specify a closure that will only be called on receipt of `PostStop` and therefore does not
    /// need to get the signal passed in. It also does not need to return a new behavior, as the actor is already stopping.
    public static func stop(_ postStop: @escaping (ActorContext<Message>) throws -> Void) -> Behavior<Message> {
        Behavior.stop(
            postStop: Behavior.receiveSignal { context, signal in
                if signal is Signals.PostStop {
                    try postStop(context)
                }
                return .stop // will be ignored
            },
            reason: .stopMyself
        )
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. If a `postStop` behavior is
    /// set, it will be used to handle the `PostStop` signal after the actor has stopped. Otherwise the last
    /// assigned behavior will be used. This allows users to use the same signal handler (chain) to process
    /// all events.
    public static func stop(postStop: Behavior<Message>) -> Behavior<Message> {
        Behavior(underlying: .stop(postStop: postStop, reason: .stopMyself))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Behavior Combinators

extension Behavior {
    /// Creates a new Behavior which on an incoming message will first execute the first (current) behavior,
    /// and if it returns `.unhandled` applies the alternative behavior passed in here.
    ///
    /// If the alternative behavior contains a `.setup` or other deferred behavior, it will be canonicalized on its first execution // TODO: make a test for it
    public func orElse(_ alternativeBehavior: Behavior<Message>) -> Behavior<Message> {
        Behavior(underlying: .orElse(first: self, second: alternativeBehavior))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Signal receiving behaviors

extension Behavior {
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
    ///     if terminated.address.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .same
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSpecificSignal` for convenience version of this behavior, simplifying handling a single type of `Signal`.
    public func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(
            underlying: .signalHandling(
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
    ///     if terminated.address.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSpecificSignal` for convenience version of this behavior, simplifying handling a single type of `Signal`.
    public static func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(
            underlying: .signalHandling(
                handleMessage: .unhandled,
                handleSignal: handle
            )
        )
    }

    /// Convenience function similar to `Behavior.receiveSignal` however allowing for easier handling of a specific signal type, e.g.:
    ///
    /// #### Example usage
    /// ```
    /// let withSignalHandling = behavior.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
    ///     if terminated.address.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSignal` which allows receiving multiple types of signals.
    public func receiveSpecificSignal<SpecificSignal: Signal>(_: SpecificSignal.Type, _ handle: @escaping (ActorContext<Message>, SpecificSignal) throws -> Behavior<Message>) -> Behavior<Message> {
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

    /// Convenience function similar to `Behavior.receiveSignal` however allowing for easier handling of a specific signal type, e.g.:
    ///
    /// #### Example usage
    /// ```
    /// return .receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
    ///     if terminated.address.name == "Juliet" {
    ///         return .stop // if Juliet died, we end ourselves as well
    ///     } else {
    ///         return .ignore
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `Signals` for a listing of signals that may be handled using this behavior.
    /// - SeeAlso: `receiveSignal` which allows receiving multiple types of signals.
    public static func receiveSpecificSignal<SpecificSignal: Signal>(_: SpecificSignal.Type, _ handle: @escaping (ActorContext<Message>, SpecificSignal) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(
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

internal extension Behavior {
    /// Allows handling signals such as termination or lifecycle events.
    @usableFromInline
    static func signalHandling(handleMessage: Behavior<Message>, handleSignal: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(underlying: .signalHandling(handleMessage: handleMessage, handleSignal: handleSignal))
    }

    /// Causes an actor to go into suspended state.
    ///
    /// MUST be canonicalized (to .suspended before storing in an `ActorCell`, as thr suspend behavior CAN NOT handle messages.
    @usableFromInline
    static func suspend<T>(handler: @escaping (Result<T, Error>) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(underlying: .suspend(handler: { result in
            try handler(result.map { $0 as! T }) // cast here is okay, as user APIs are typed, so we should always get a T
        }))
    }

    /// Represents a behavior in suspended state.
    ///
    /// A suspended actor will only react to system messages, until it is resumed.
    /// This usually happens when an async operation that caused the suspension
    /// is completed.
    @usableFromInline
    static func suspended(previousBehavior: Behavior<Message>, handler: @escaping (Result<Any, Error>) throws -> Behavior<Message>) -> Behavior<Message> {
        Behavior(underlying: .suspended(previousBehavior: previousBehavior, handler: handler))
    }

    /// Creates internal representation of stopped behavior, see `stop(_:)` for public api.
    @usableFromInline
    static func stop(postStop: Behavior<Message>? = nil, reason: StopReason) -> Behavior<Message> {
        Behavior(underlying: .stop(postStop: postStop, reason: reason))
    }

    /// Internal way of expressing a failed actor, retains the behavior that has failed internally.
    ///
    /// - parameters
    ///   - error: cause of the actor's failing.
    @usableFromInline
    func fail(cause: Supervision.Failure) -> Behavior<Message> {
        Behavior(underlying: _Behavior<Message>.failed(behavior: self, cause: cause))
    }
}

@usableFromInline
internal enum _Behavior<Message: ActorMessage> {
    case setup(_ onStart: (ActorContext<Message>) throws -> Behavior<Message>)

    case receive(_ handle: (ActorContext<Message>, Message) throws -> Behavior<Message>)
    case receiveAsync(_ handle: @Sendable (ActorContext<Message>, Message) async throws -> Behavior<Message>)

    case receiveMessage(_ handle: (Message) throws -> Behavior<Message>)
    case receiveMessageAsync(_ handle: @Sendable (Message) async throws -> Behavior<Message>)

    indirect case stop(postStop: Behavior<Message>?, reason: StopReason)
    indirect case failed(behavior: Behavior<Message>, cause: Supervision.Failure)

    indirect case signalHandling(
        handleMessage: Behavior<Message>,
        handleSignal: (ActorContext<Message>, Signal) throws -> Behavior<Message>
    )
    case same
    case ignore
    case unhandled

    indirect case intercept(behavior: Behavior<Message>, with: Interceptor<Message>) // TODO: for printing it would be nicer to have "supervised" here, though, modeling wise it is exactly an intercept

    indirect case orElse(first: Behavior<Message>, second: Behavior<Message>)

    case suspend(handler: (Result<Any, Error>) throws -> Behavior<Message>)
    indirect case suspended(previousBehavior: Behavior<Message>, handler: (Result<Any, Error>) throws -> Behavior<Message>)
}

@usableFromInline
internal enum StopReason {
    /// the actor decided to stop and returned Behavior.stop
    case stopMyself
    /// a stop was requested by the parent, i.e. `context.stop(child:)`
    case stopByParent
    /// the actor experienced a failure that was not handled by supervision
    case failure(Supervision.Failure)
}

public enum IllegalBehaviorError<Message: ActorMessage>: Error {
    /// Some behaviors, like `.same` and `.unhandled` are not allowed to be used as initial behaviors.
    /// See their individual documentation for the rationale why that is so.
    case notAllowedAsInitial(_ behavior: Behavior<Message>)

    /// Too deeply nested deferred behaviors (such a .setup) are not supported,
    /// and are often an indication of programming errors - e.g. infinitely infinitely
    /// growing behavior depth may be a mistake of accidentally needlessly wrapping behaviors with decorators they already contained.
    ///
    /// While technically it would be possible to support very very deep behaviors, in practice those are rare and Swift Distributed Actors
    /// currently opts to eagerly fail for those situations. If you have a legitimate need for such deeply nested deferred behaviors,
    /// please do not hesitate to open a ticket.
    case tooDeeplyNestedBehavior(reached: Behavior<Message>, depth: Int)

    /// Not all behavior transitions are legal and can't be prevented statically.
    /// Example:
    /// Returning a `.same` directly from within a `.setup` like so: `.setup { _ in return .same }`is treated as illegal,
    /// as it has a high potential for resulting in an eagerly infinitely looping during behavior canonicalization.
    /// If such behavior is indeed what you want, you can return the behavior containing the setup rather than the `.same` marker.
    case illegalTransition(from: Behavior<Message>, to: Behavior<Message>)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Intercepting Messages

extension Behavior {
    /// Intercepts all incoming messages and signals, allowing to transform them before they are delivered to the wrapped behavior.
    // TODO: more docs
    public static func intercept(behavior: Behavior<Message>, with interceptor: Interceptor<Message>) -> Behavior<Message> {
        Behavior(underlying: .intercept(behavior: behavior, with: interceptor))
    }
}

/// Used in combination with `Behavior.intercept` to intercept messages and signals delivered to a behavior.
open class Interceptor<Message: ActorMessage> {
    public init() {}

    @inlinable
    open func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        try target.interpretMessage(context: context, message: message)
    }

    @inlinable
    open func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        try target.interpretSignal(context: context, signal: signal)
    }

    @inlinable
    open func isSame(as other: Interceptor<Message>) -> Bool {
        self === other
    }
}

extension Interceptor {
    @inlinable
    static func handleMessage(context: ActorContext<Message>, behavior: Behavior<Message>, interceptor: Interceptor<Message>, message: Message) throws -> Behavior<Message> {
        let next = try interceptor.interceptMessage(target: behavior, context: context, message: message)

        return try Interceptor.deduplicate(context: context, behavior: next, interceptor: interceptor)
    }

    @inlinable
    static func deduplicate(context: ActorContext<Message>, behavior: Behavior<Message>, interceptor: Interceptor<Message>) throws -> Behavior<Message> {
        func deduplicate0(_ behavior: Behavior<Message>) -> Behavior<Message> {
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

// MARK: Behavior interpretation

/// Offers the capability to interpret messages and signals
public extension Behavior {
    /// Interpret the passed in message.
    ///
    /// Note: The returned behavior MUST be `Behavior.canonicalize`-ed in the vast majority of cases.
    // Implementation note: We don't do so here automatically in order to keep interpretations transparent and testable.
    @inlinable
    func interpretMessage(context: ActorContext<Message>, message: Message, file: StaticString = #file, line: UInt = #line) throws -> Behavior<Message> {
        switch self.underlying {
        case .receiveMessage(let recv): return try recv(message)
        case .receiveMessageAsync(let recv): return self.receiveMessageAsync(recv, message)
        case .receive(let recv): return try recv(context, message)
        case .receiveAsync(let recv): return self.receiveAsync(recv, message)
        case .signalHandling(let recvMsg, _): return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests
        case .intercept(let inner, let interceptor): return try Interceptor.handleMessage(context: context, behavior: inner, interceptor: interceptor, message: message)
        case .orElse(let first, let second): return try self.interpretOrElse(context: context, first: first, orElse: second, message: message, file: file, line: line)

        // illegal to attempt interpreting at the following behaviors (e.g. should have been canonicalized before):
        case .same: fatalError("Illegal attempt to interpret message with .same behavior! Behavior should have been canonicalized. This is a bug, please open a ticket.", file: file, line: line)
        case .ignore: fatalError("Illegal attempt to interpret message with .ignore behavior! Behavior should have been canonicalized before interpreting; This is a bug, please open a ticket.", file: file, line: line)
        case .unhandled: fatalError("Illegal attempt to interpret message with .unhandled behavior! Behavior should have been canonicalized before interpreting; This is a bug, please open a ticket.", file: file, line: line)

        case .setup:
            return fatalErrorBacktrace("""
                                       Illegal attempt to interpret message with .setup behavior! Behaviors MUST be canonicalized before interpreting. This is a bug, please open a ticket. 
                                       Message: \(message): \(type(of: message))
                                       Actor address: \(context.address.detailedDescription)
                                       System: \(context.system)
                                       """, file: file, line: line)

        case .stop:
            return .unhandled
        case .failed:
            return .unhandled

        case .suspend:
            fatalError("Illegal to attempt to interpret message with .suspend behavior! Behavior should have been canonicalized. This is a bug, please open a ticket.", file: file, line: line)
        case .suspended:
            fatalError("""
            No message should ever be delivered to a .suspended behavior!
            Message: \(message)
            Actor: \(context)
            This is a bug, please open a ticket.
            """, file: file, line: line)
        }
    }

    /// Attempts interpreting signal using the current behavior, or returns `Behavior.unhandled` if no `Behavior.signalHandling` was found.
    @inlinable
    func interpretSignal(context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
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
            return try Behavior(underlying: .failed(behavior: behavior.interpretSignal(context: context, signal: signal), cause: cause))

        case .signalHandling(_, let handleSignal):
            return try handleSignal(context, signal)
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
internal extension Behavior {
    @inlinable
    func interpretOrElse(
        context: ActorContext<Message>,
        first: Behavior<Message>, orElse second: Behavior<Message>, message: Message,
        file: StaticString = #file, line: UInt = #line
    ) throws -> Behavior<Message> {
        var nextBehavior = try first.interpretMessage(context: context, message: message, file: file, line: line)
        if nextBehavior.isUnhandled {
            nextBehavior = try second.interpretMessage(context: context, message: message, file: file, line: line)
        }
        return nextBehavior
    }

    /// Applies `interpretMessage` to an iterator of messages, while canonicalizing the behavior after every reduction.
    @inlinable
    func interpretMessages<Iterator: IteratorProtocol>(context: ActorContext<Message>, messages: inout Iterator) throws -> Behavior<Message> where Iterator.Element == Message {
        var currentBehavior: Behavior<Message> = self
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

    /// Validate if a Behavior is legal to be used as "initial" behavior (when an Actor is spawned),
    /// since certain behaviors do not make sense as initial behavior.
    @inlinable
    func validateAsInitial() throws {
        switch self.underlying {
        case .same: throw IllegalBehaviorError.notAllowedAsInitial(self)
        case .unhandled: throw IllegalBehaviorError.notAllowedAsInitial(self)
        default: return ()
        }
    }

    /// Same as `validateAsInitial`, however useful in chaining expressions as it returns itself when the validation has passed successfully.
    @inlinable
    func validatedAsInitial() throws -> Behavior<Message> {
        try self.validateAsInitial()
        return self
    }

    func validateAsInitialFatal(file: String = #file, line: UInt = #line) {
        switch self.underlying {
        case .same, .unhandled: fatalError("Illegal initial behavior! Attempted to spawn(\(self)) at \(file):\(line)")
        default: return
        }
    }

    /// Shorthand for checking if the current behavior is a `.unhandled`
    @inlinable
    var isUnhandled: Bool {
        switch self.underlying {
        case .unhandled: return true
        default: return false
        }
    }

    /// Shorthand for checking if the `Behavior` is `.stop` or `.failed`.
    @inlinable
    var isTerminal: Bool {
        switch self.underlying {
        case .stop, .failed: return true
        default: return false
        }
    }

    /// Shorthand for checking if the `Behavior` is NOT `.stop` or `.failed`.
    @inlinable
    var isStillAlive: Bool {
        !self.isTerminal
    }

    @inlinable
    var isSuspend: Bool {
        switch self.underlying {
        case .suspend: return true
        default: return false
        }
    }

    @inlinable
    var isSuspended: Bool {
        switch self.underlying {
        case .suspended: return true
        default: return false
        }
    }

    @inlinable
    var isSame: Bool {
        switch self.underlying {
        case .same: return true
        default: return false
        }
    }

    @inlinable
    var isSetup: Bool {
        switch self.underlying {
        case .setup: return true
        default: return false
        }
    }

    /// Returns `false` if canonicalizing behavior is known to not create a change in behavior.
    /// For example `.same` or semantically equivalent behaviors.
    @inlinable
    var isChanging: Bool {
        switch self.underlying {
        case .same, .ignore, .unhandled: return false
        default: return true
        }
    }

    /// Ensure that the behavior is in "canonical form", i.e. that all setup behaviors are reduced (run)
    /// before storing the behavior. This process may trigger executing setup(onStart) behaviors.
    ///
    /// Warning: Remember that a first start (or re-start) of a behavior must be triggered using `Behavior.start`
    ///          rather than just canonicalize since we want to recursively trigger
    ///
    /// - Throws: `IllegalBehaviorError.tooDeeplyNestedBehavior` when a too deeply nested behavior is found,
    ///           in order to avoid attempting to start an possibly infinitely deferred behavior.
    @inlinable
    func canonicalize(_ context: ActorContext<Message>, next: Behavior<Message>) throws -> Behavior<Message> {
        guard self.isStillAlive else {
            return self // ignore, we're already dead and cannot become any other behavior
        }

        // Note: on purpose not implemented as tail recursive function since tail-call elimination is not guaranteed
        let failAtDepth = context.system.settings.actor.maxBehaviorNestingDepth

        // TODO: what if already stopped or failed

        func canonicalize0(_ context: ActorContext<Message>, base: Behavior<Message>, next: Behavior<Message>, depth: Int) throws -> Behavior<Message> {
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
                    let innerCanonicalized: Behavior<Message> = try canonicalize0(context, base: inner, next: .same, depth: deeper)
                    return .intercept(behavior: innerCanonicalized, with: interceptor)

                case .signalHandling(let onMessage, let onSignal):
                    return .signalHandling(
                        handleMessage: try canonicalize0(context, base: canonical, next: onMessage, depth: deeper),
                        handleSignal: onSignal
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
    @inlinable
    func start(context: ActorContext<Message>) throws -> Behavior<Message> {
        let failAtDepth = context.system.settings.actor.maxBehaviorNestingDepth

        func start0(_ behavior: Behavior<Message>, depth: Int) throws -> Behavior<Message> {
            guard depth < failAtDepth else {
                throw IllegalBehaviorError.tooDeeplyNestedBehavior(reached: behavior, depth: depth)
            }

            // Note: DO NOT use `default:`, we always want to explicitly know when we add a behavior and add specific handling here.
            switch behavior.underlying {
            case .intercept(let inner, let interceptor):
                // FIXME: this should technically offload onto storage and then apply them again...
                return .intercept(behavior: try start0(inner, depth: depth + 1), with: interceptor)

            case .setup(let onStart):
                let started: Behavior<Message> = try onStart(context)
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
    @inlinable
    func existsInStack(_ predicate: (Behavior<Message>) -> Bool) -> Bool {
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

extension Behavior: CustomStringConvertible {
    @inlinable
    public var description: String {
        let fqcn = String(reflecting: Behavior<Message>.self)
        return "\(fqcn).\(self.underlying)"
    }
}
