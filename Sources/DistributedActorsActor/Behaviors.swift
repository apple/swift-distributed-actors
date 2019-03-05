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

@usableFromInline
internal enum _Behavior<Message> {
    // TODO stayReceive(_ handle: (ActorContext<Message>, Message) throws -> ()) which automatically does `return .same`?

    // TODO: receiveExactly(_ expected: Message, orElse: Behavior<Message> = /* .ignore */, atMost = /* 5.seconds */)

    case receiveMessage(_ handle: (Message) throws -> Behavior<Message>) // TODO: make them throws?
    case receive(_ handle: (ActorContext<Message>, Message) throws -> Behavior<Message>) // TODO: make them throws?
    case setup(_ onStart: (ActorContext<Message>) throws -> Behavior<Message>)

    // TODO: rename it, as we not want to give of the impression this is "the" way to have custom behaviors, all ways are valid (!) (store something in a let etc)
    case custom(behavior: ActorBehavior<Message>)
    case same
    indirect case stopped(postStop: Behavior<Message>?)
    indirect case signalHandling(handleMessage: Behavior<Message>,
                                 handleSignal: (ActorContext<Message>, Signal) throws -> Behavior<Message>)
    indirect case intercept(behavior: Behavior<Message>, with: Interceptor<Message>) // TODO for printing it would be nicer to have "supervised" here, though, modeling wise it is exactly an intercept
    case unhandled
    case ignore
    indirect case orElse(first: Behavior<Message>, second: Behavior<Message>)

    // Internal only

    case failed(error: Error)
    case suspend(handler: (Result<Any, ExecutionError>) throws -> Behavior<Message>)
    indirect case suspended(previousBehavior: Behavior<Message>, handler: (Result<Any, ExecutionError>) throws -> Behavior<Message>)
}

/// A `Behavior` is what executes then an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public struct Behavior<Message> {
    @usableFromInline
    internal let underlying: _Behavior<Message>
}

// MARK: Behavior combinators

extension Behavior {

    /// Creates a new Behavior which on an incoming message will first execute the first (current) behavior,
    /// and if it returns `.unhandled` applies the alternative behavior passed in here.
    ///
    /// If the alternative behavior contains a `.setup` or other deferred behavior, it will be canonicalized on its first execution // TODO: make a test for it
    public func orElse(_ alternativeBehavior: Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .orElse(first: self, second: alternativeBehavior))
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. The last assigned behavior
    /// will be used to handle the `PostStop` signal after the actor has stopped. This allows users to use
    /// the same signal handler (chain) to process all events.
    public static var stopped: Behavior<Message> {
        return Behavior(underlying: .stopped(postStop: nil))
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. This is a convenienve overload that
    /// allows users to specify a closure that will only be called on receival of `PostStop` and therefore does not
    /// need to get the signal passed in. It also does not need to return a new behavior, as the actor is already stopping.
    public static func stopped(_ postStop: @escaping (ActorContext<Message>) throws -> ()) -> Behavior<Message> {
        return Behavior(underlying: .stopped(postStop: Behavior.receiveSignal { context, signal in
            if signal is Signals.PostStop {
                try postStop(context)
            }
            return .same // will be ignored
        }))
    }

    /// A stopped behavior signifies that the actor will cease processing messages (they will be drained to dead letters),
    /// and the actor itself will stop. Return this behavior to stop your actors. If a `postStop` behavior is
    /// set, it will be used to handle the `PostStop` signal after the actor has stopped. Otherwise the last
    /// assigned behavior will be used. This allows users to use the same signal handler (chain) to process
    /// all events.
    public static func stopped(postStop: Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .stopped(postStop: postStop))
    }

    /// Defines that the same behavior should remain in use for handling the next message.
    public static var same: Behavior<Message> {
        return Behavior(underlying: .same)
    }

    /// Causes a message to be assumed unhandled by the runtime.
    /// Unhandled messages are logged by default, and other behaviors may use this information to implement `apply1.orElse(apply2)` style logic.
    /// TODO: and their logging rate should be configurable
    public static var unhandled: Behavior<Message> {
        return Behavior(underlying: .unhandled)
    }

    /// Ignore an incoming message.
    ///
    /// Ignoring a message differs from handling it with "unhandled" since the later can be acted upon by another behavior,
    /// such as "orElse" which can be used for behavior composition. `ignore` on the other hand does "consume" the message,
    /// in the sense that we did handle it, however simply chose to ignore it.
    ///
    /// Returning `ignore` implies remaining the same behavior, the same way as would returning `.same`.
    public static var ignore: Behavior<Message> {
        return Behavior(underlying: .ignore)
    }

    /// Allows defining actors by extending the [[ActorBehavior]] class.
    ///
    /// This allows for easier storage of mutable state, since one can utilize instance variables for this,
    /// rather than closing over state like it is typical in the more function heavy (class-less) style.
    // TODO: rename it, as we not want to give of the impression this is "the" way to have custom behaviors, all ways are valid (!) (store something in a let etc)
    public static func custom(behavior: ActorBehavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .custom(behavior: behavior))
    }

    /// Intercepts all incoming messages and signals, allowing to transform them before they are delivered to the wrapped behavior.
    public static func intercept(behavior: Behavior<Message>, with interceptor: Interceptor<Message>) -> Behavior<Message> {
        return Behavior(underlying: .intercept(behavior: behavior, with: interceptor))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    public static func receive(_ handle: @escaping (ActorContext<Message>, Message) throws -> Behavior<Message>) -> Behavior {
        return Behavior(underlying: .receive(handle))
    }

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    public static func receiveMessage(_ handle: @escaping (Message) throws -> Behavior<Message>) -> Behavior {
        return Behavior(underlying: .receiveMessage(handle))
    }

    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// This can be used to obtain the context, logger or perform actions right when the actor starts
    /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
    public static func setup(_ onStart: @escaping (ActorContext<Message>) throws -> Behavior<Message>) -> Behavior {
        return Behavior(underlying: .setup(onStart))
    }
}

// MARK: Internal behavior creators

extension Behavior {
    /// Internal way of expressing a failed actor.
    ///
    /// **Associated Values**
    ///   - `error` cause of the actor's failing.
    @usableFromInline
    internal static func failed(error: Error) -> Behavior<Message> {
        return Behavior(underlying: .failed(error: error))
    }

    /// Allows handling signals such as termination or lifecycle events.
    @usableFromInline
    internal static func signalHandling(handleMessage: Behavior<Message>, handleSignal: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .signalHandling(handleMessage: handleMessage, handleSignal: handleSignal))
    }

    /// Causes an actor to go into suspended state
    @usableFromInline
    internal static func suspend<T>(handler: @escaping (Result<T, ExecutionError>) throws -> Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .suspend(handler: { try handler($0.map { $0 as! T }) })) // cast here is okay, as user APIs are typed, so we should always get a T
    }

    /// Marks an actor as being suspended
    ///
    /// A suspended actor will only react to system message, until it is resumed.
    /// This usually happens when an async operation that caused the suspension
    /// is completed.
    @usableFromInline
    internal static func suspended(previousBehavior: Behavior<Message>, handler: @escaping (Result<Any, ExecutionError>) throws -> Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .suspended(previousBehavior: previousBehavior, handler: handler))
    }
}

// MARK: Signal receiving behaviors

extension Behavior {

    /// While throwing in signal handlers is not permitted, supervision does take care of faults that could occur while handling a signal
    public func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .signalHandling(handleMessage: self, handleSignal: handle))
    }

    /// -- || --
    public static func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Behavior<Message> {
        return Behavior(underlying: .signalHandling(handleMessage: .unhandled, handleSignal: handle))
    }
}

public enum IllegalBehaviorError<M>: Error {
    /// Some behaviors, like `.same` and `.unhandled` are not allowed to be used as initial behaviors.
    /// See their individual documentation for the rationale why that is so.
    case notAllowedAsInitial(_ behavior: Behavior<M>)

    /// Too deeply nested deferred behaviors (such a .setup) are not supported,
    /// and are often an indication of programming errors - e.g. infinitely infinitely
    /// growing behavior depth may be a mistake of accidentally needlessly wrapping behaviors with decorators they already contained.
    ///
    /// While technically it would be possible to support very very deep behaviors, in practice those are rare and Swift Distributed Actors
    /// currently opts to eagerly fail for those situations. If you have a legitimate need for such deeply nested deferred behaviors,
    /// please do not hesitate to open a ticket.
    case tooDeeplyNestedBehavior(reached: Behavior<M>, depth: Int)

    /// Not all behavior transitions are legal and can't be prevented statically.
    /// Example: 
    /// Returning a `.same` directly from within a `.setup` like so: `.setup { _ in return .same }`is treated as illegal,
    /// as it has a high potential for resulting in an eagerly infinitely looping during behavior canonicalization.
    /// If such behavior is indeed what you want, you can return the behavior containing the setup rather than the `.same` marker.
    case illegalTransition(from: Behavior<M>, to: Behavior<M>)
}


/// Allows writing actors in "class style" by extending this behavior and spawning it using `.custom(MyBehavior())`
open class ActorBehavior<Message> {
    open func receive(context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        return undefined(hint: "MUST override receive(context:message:) when extending ActorBehavior")
    }

    open func receiveSignal(context: ActorContext<Message>, signal: Signal) -> Behavior<Message> {
        return .unhandled
    }
}

// MARK: Interceptor

/// Used in combination with `Behavior.intercept` to intercept messages and signals delivered to a behavior.
open class Interceptor<Message> {
    public init() {}

    @inlinable
    open func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        return try target.interpretMessage(context: context, message: message)
    }

    @inlinable
    open func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        return try target.interpretSignal(context: context, signal: signal)
    }

    @inlinable
    open func isSame(as other: Interceptor<Message>) -> Bool {
        return self === other
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
                case .intercept(_, let otherInterceptor):   return interceptor.isSame(as: otherInterceptor)
                default:                                    return false
                }
            }

            if hasDuplicatedIntercept {
                return behavior
            } else {
                return .intercept(behavior: behavior, with: interceptor)
            }
        }

        let started = try behavior.start(context: context)

        if case let .stopped(.some(postStop)) = started.underlying {
            return .stopped(postStop: deduplicate0(postStop))
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
    /// Note: The returned behavior MUST be [[Behavior.canonicalize]]-ed in the vast majority of cases.
    // Implementation note: We don't do so here automatically in order to keep interpretations transparent and testable.
    @inlinable
    func interpretMessage(context: ActorContext<Message>, message: Message, file: StaticString = #file, line: UInt = #line) throws -> Behavior<Message> {
        switch self.underlying {
        case let .receiveMessage(recv):          return try recv(message)
        case let .receive(recv):                 return try recv(context, message)
        case let .custom(behavior):              return try behavior.receive(context: context, message: message) // TODO rename "custom"
        case let .signalHandling(recvMsg, _):    return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests
        case let .intercept(inner, interceptor): return try Interceptor.handleMessage(context: context, behavior: inner, interceptor: interceptor, message: message)
        case let .orElse(first, second):         return try self.interpretOrElse(context: context, first: first, orElse: second, message: message, file: file, line: line)
        case .ignore:                            return .same // ignore message and remain .same
        case .unhandled:                         return FIXME("NOT IMPLEMENTED YET")

        // illegal to attempt interpreting at the following behaviors (e.g. should have been canonicalized before):
        case .same:                     return FIXME("Illegal to attempt to interpret message with .same behavior! Behavior should have been canonicalized. This could be a Swift Distributed Actors bug.", file: file, line: line)
        case .setup:                    return FIXME("Illegal attempt to interpret message with .setup behavior! Behaviors MUST be canonicalized before interpreting. This could be a Swift Distributed Actors bug.", file: file, line: line)
        case .suspend:                  return FIXME("Illegal to attempt to interpret message with .suspend behavior! Behavior should have been canonicalized. This could be a Swift Distributed Actors bug.", file: file, line: line)
        case .failed(let error): return FIXME("Illegal attempt to interpret message with .failed behavior! Reason for original failure was: \(error)", file: file, line: line)
        case .stopped:                  return FIXME("No message should ever be delivered to a .stopped behavior! This is a mailbox bug.", file: file, line: line)
        case .suspended:
            context.log.error("No message should ever be delivered to a .suspended behavior! This is a mailbox bug. \(message)")
            return FIXME("No message should ever be delivered to a .suspended behavior! This is a mailbox bug.", file: file, line: line)
        }
    }

    /// Attempts interpreting signal using the current behavior, or returns `Behavior.unhandled`
    /// if no `Behavior.signalHandling` was found.
    @inlinable
    func interpretSignal(context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        switch self.underlying {
        case let .stopped(.some(postStop)):
            return try .stopped(postStop: postStop.interpretSignal(context: context, signal: signal))
        case .signalHandling(_, let handleSignal):
            return try handleSignal(context, signal)
        case let .intercept(behavior, interceptor):
            return try interceptor.interceptSignal(target: behavior, context: context, signal: signal) // TODO do we need to try?
        case let .suspended(previous, handler):
            let nextBehavior = try previous.interpretSignal(context: context, signal: signal)
            if nextBehavior.isTerminal {
                return nextBehavior
            } else {
                return try .suspended(previousBehavior: previous.canonicalize(context, next: nextBehavior), handler: handler)
            }
        default:
            // no signal handling installed is semantically equivalent to unhandled
            return .unhandled
        }
    }
}

// MARK: Internal tools to work with Behaviors

/// Internal operations for behavior manipulation
internal extension Behavior {

    @inlinable
    func interpretOrElse(context: ActorContext<Message>,
                         first: Behavior<Message>, orElse second: Behavior<Message>, message: Message,
                         file: StaticString = #file, line: UInt = #line) throws -> Behavior<Message> {
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
        case .same:      throw IllegalBehaviorError.notAllowedAsInitial(self)
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

    func validateAsInitialFatal(file: StaticString = #file, line: UInt = #line) {
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

    /// Shorthand for checking if the `Behavior` is `.stopped` or `.failed`.
    @inlinable
    var isTerminal: Bool {
        switch self.underlying {
        case .stopped, .failed: return true
        default: return false
        }
    }

    /// Shorthand for checking if the `Behavior` is NOT `.stopped` or `.failed`.
    @inlinable
    var isStillAlive: Bool {
        return !self.isTerminal
    }

    @inlinable
    var isSuspend: Bool {
        switch self.underlying {
        case .suspend:      return true
        default:            return false
        }
    }

    @inlinable
    var isSuspended: Bool {
        switch self.underlying {
        case .suspended:    return true
        default:            return false
        }
    }

    @inlinable
    var isSame: Bool {
        switch self.underlying {
        case .same: return true
        default:    return false
        }
    }

    @inlinable
    var isSetup: Bool {
        switch self.underlying {
        case .setup:    return true
        default:        return false
        }
    }

    /// Ensure that the behavior is in "canonical form", i.e. that all setup behaviors are reduced (run)
    /// before storing the behavior. This process may trigger executing setup(onStart) behaviors.
    ///
    /// Warning: Remember that a first start (or re-start) of a behavior must be triggered using `Behavior.start`
    ///          rather than just canonicalize since we want to recursively trigger
    @inlinable
    func canonicalize(_ context: ActorContext<Message>, next: Behavior<Message>) throws -> Behavior<Message> {
        // Note: on purpose not implemented as tail recursive function since tail-call elimination is not guaranteed

        var canonical = next
        while true {
            switch canonical.underlying {
            case .same:
                if self.isSetup {
                    throw IllegalBehaviorError.illegalTransition(from: self, to: next)
                } else {
                    return self
                }

            case .ignore:               return self
            case .unhandled:            return self
            case .custom:               return self
            case .stopped(.none):       return .stopped(postStop: self)
            case .stopped(.some):       return canonical
            case .suspend(let handler): return .suspended(previousBehavior: self, handler: handler)

            case .setup(let onStart):
                canonical = try onStart(context)

            case let .intercept(inner, interceptor):
                let innerCanonicalized: Behavior<Message> = try inner.canonicalize(context, next: .same)
                return .intercept(behavior: innerCanonicalized, with: interceptor)

            default:
                return canonical
            }
        }
    }

    /// Starting a behavior means triggering all onStart actions of nested `.setup` calls.
    /// Interceptors are left in-place, and other behaviors remain unaffected.
    ///
    /// - Throws: `IllegalBehaviorError.tooDeeplyNestedBehavior` when a too deeply nested behavior is found,
    ///           in order to avoid attempting to start an possibly infinitely deferred behavior.
    // TODO make not recursive perhaps since could blow up on large chain?
    @inlinable func start(context: ActorContext<Message>) throws -> Behavior<Message> {
        let failAtDepth = context.system.settings.actor.maxBehaviorNestingDepth

        func start0(_ behavior: Behavior<Message>, depth: Int) throws -> Behavior<Message> {
            guard depth < failAtDepth else {
                throw IllegalBehaviorError.tooDeeplyNestedBehavior(reached: behavior, depth: depth)
            }

            switch behavior.underlying {
            case let .intercept(inner, interceptor):
                // FIXME this should technically offload onto storage and then apply them again...
                return .intercept(behavior: try start0(inner, depth: depth + 1), with: interceptor)

            case .setup(let onStart):
                let started: Behavior<Message> = try onStart(context)
                return try start0(started, depth: depth + 1)

            case .signalHandling(let onMessageBehavior, let onSignal):
                return .signalHandling(handleMessage: try start0(onMessageBehavior, depth: depth + 1), handleSignal: onSignal)

            default:
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
        case .intercept(let behavior, _):   return behavior.existsInStack(predicate)
        case let .orElse(first, second):    return first.existsInStack(predicate) || second.existsInStack(predicate)
        case let .stopped(.some(postStop)): return postStop.existsInStack(predicate)
        default:                            return false
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
