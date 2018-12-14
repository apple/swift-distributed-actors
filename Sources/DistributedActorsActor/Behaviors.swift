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

/// A `Behavior` is what executes then an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public enum Behavior<Message> {

    // TODO likely move away into structs with these, for evolvability?

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    case receiveMessage(_ handle: (Message) throws -> Behavior<Message>) // TODO: make them throws?

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    case receive(_ handle: (ActorContext<Message>, Message) throws -> Behavior<Message>) // TODO: make them throws?

    // TODO: receiveExactly(_ expected: Message, orElse: Behavior<Message> = /* .ignore */, atMost = /* 5.seconds */)

    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// This can be used to obtain the context, logger or perform actions right when the actor starts
    /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
    case setup(_ onStart: (ActorContext<Message>) throws -> Behavior<Message>)

    /// Allows defining actors by extending the [[ActorBehavior]] class.
    ///
    /// This allows for easier storage of mutable state, since one can utilize instance variables for this,
    /// rather than closing over state like it is typical in the more function heavy (class-less) style.
    // TODO: rename it, as we not want to give of the impression this is "the" way to have custom behaviors, all ways are valid (!) (store something in a let etc)
    case custom(behavior: ActorBehavior<Message>)

    /// Defines that the same behavior should remain
    case same

    /// A stopped behavior signifies that the actor will cease processing messages (they will be "dropped"),
    /// and the actor itself will stop. Return this behavior to stop your actors.
    case stopped

    case failed(error: Error)

    /// Allows handling signals such as termination or lifecycle events.
    indirect case signalHandling(handleMessage: Behavior<Message>,
                                 handleSignal: (ActorContext<Message>, Signal) throws -> Behavior<Message>)

    /// Intercepts all incoming messages and signals, allowing to transform them before they are delivered to the wrapped behavior.
    indirect case intercept(behavior: Behavior<Message>, with: Interceptor<Message>) // TODO for printing it would be nicer to have "supervised" here, though, modeling wise it is exactly an intercept

    /// Causes a message to be assumed unhandled by the runtime.
    /// Unhandled messages are logged by default, and other behaviors may use this information to implement `apply1.orElse(apply2)` style logic.
    /// TODO: and their logging rate should be configurable
    case unhandled

    /// Ignore an incoming message.
    ///
    /// Ignoring a message differs from handling it with "unhandled" since the later can be acted upon by another behavior,
    /// such as "orElse" which can be used for behavior composition. `ignore` on the other hand does "consume" the message,
    /// in the sense that we did handle it, however simply chose to ignore it.
    ///
    /// Returning `ignore` implies remaining the same behavior, the same way as would returning `.same`.
    case ignore

    /// An incoming message or signal is first applied to the `first` behavior,
    /// and if it returns `Behavior.unhandled` the second behavior is invoked.
    ///
    /// The orElse behavior may be used to arbitrarily deeply nest such alternatives.
    indirect case orElse(first: Behavior<Message>, second: Behavior<Message>)

//  /// Apply given supervision to behavior
//  /// TODO: more docs
//  indirect case supervise(_ behavior: Behavior<Message>, strategy: (Supervision.Failure) -> Supervision.Directive) // TODO: I assume this causes us to lose all benefits of being an enum? since `indirect`
//
//  /// Supervise the passed in behavior and return the such supervised behavior.
//  /// The returned behavior will supervised be given supervision decision to any crash of this actor.to behavior
//  public static func supervise(_ behavior: Behavior<Message>, directive: Supervision.Directive) -> Behavior<Message> {
//    return .supervise(behavior) { _ in
//      directive
//    }
//  }

}

// MARK: Signal receiving behaviors

extension Behavior {

    public func orElse(_ alternativeBehavior: Behavior<Message>) -> Behavior<Message> {
        return .orElse(first: self, second: alternativeBehavior)
    }

    public func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) -> Behavior<Message>) -> Behavior<Message> {
        return Behavior<Message>.signalHandling(handleMessage: self, handleSignal: handle)
    }

    public static func receiveSignal(_ handle: @escaping (ActorContext<Message>, Signal) -> Behavior<Message>) -> Behavior<Message> {
        return Behavior<Message>.signalHandling(handleMessage: .unhandled, handleSignal: handle)
    }
}

// MARK: Supervision behaviors

extension Behavior {

    public static func supervise(_ behavior: Behavior<Message>, withStrategy strategy: SupervisionStrategy) -> Behavior<Message> {
        let supervisor: Supervisor<Message> = Supervision.supervisorFor(strategy)
        return Behavior<Message>.intercept(behavior: behavior, with: supervisor)
    }

//    // TODO not happy with API types here
//    public func supervised(with strategy: SupervisionStrategy) -> Behavior<Message> {
//
//    }
}


public enum IllegalBehaviorError<M>: Error {
    /// Some behaviors, like `.same` and `.unhandled` are not allowed to be used as initial behaviors.
    /// See their individual documentation for the rationale why that is so.
    indirect case notAllowedAsInitial(_ behavior: Behavior<M>)
}


/// Allows writing actors in "class style" by extending this behavior and spawning it using `.custom(MyBehavior())`
open class ActorBehavior<Message> {
    open func receive(context: ActorContext<Message>, message: Message) -> Behavior<Message> {
        return undefined(hint: "MUST override receive(context:message:) when extending ActorBehavior")
    }

    open func receiveSignal(context: ActorContext<Message>, signal: Signal) -> Behavior<Message> {
        return .unhandled
    }
}

// MARK: Interceptor

/// Used in combination with `Behavior.intercept` to intercept messages and signals delivered to a behavior.

public class Interceptor<Message> {
    // TODO: spent a lot of time trying to figure out the balance between using a struct or class here,
    //       struct makes it quite weird to use, and using a protocol is hard since we need the associated type
    //       and the supervisor has to be stored inside of the intercept() behavior, so that won't fly...
    //       Implementing using class for now, and we may revisit; though supervision does not need to be high performance
    //       it is more about "weight of actor ref that contains many layers of supervisors. though perhaps I'm over worrying

    @inlinable func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        return try target.interpretMessage(context: context, message: message)
    }

    @inlinable func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        // no-op interception by default; interceptors may be interested only in the signals or only in messages after all
        return try target.interpretSignal(context: context, signal: signal)
    }
}

/// Convenience factories for creating simple in-line defined interceptors.
/// For more complex interceptors which may need ot keep state it is recommended to extend `Interceptor` directly.
///
/// An interceptor MAY apply an incoming `message` to the `target` behavior or choose to not do so
/// which results in dropping the message. In this case it SHOULD return `Behavior.ignore` or `Behavior.unhandled`,
/// such that the usual logging mechanisms work as expected.
///
/// - SeeAlso: `Interceptor`
enum Intercept {

    /// Create unnamed `Interceptor` which intercepts all incoming messages.
    public static func messages<Message>(file: StaticString = #file, line: UInt = #line,
                                         _ onMessage: @escaping (Behavior<Message>, ActorContext<Message>, Message) throws -> Behavior<Message>) -> Interceptor<Message> {
        return FunctionInterceptor(
            interceptMessage: onMessage,
            interceptSignal: { try $0.interpretSignal(context: $1, signal: $2) },
            file: file, line: line
        )
    }

    public static func signals<Message>(file: StaticString = #file, line: UInt = #line,
                                        _ onSignal: @escaping (Behavior<Message>, ActorContext<Message>, Signal) throws -> Behavior<Message>) -> Interceptor<Message> {
        return FunctionInterceptor(
            interceptMessage: { try $0.interpretMessage(context: $1, message: $2) },
            interceptSignal: onSignal,
            file: file, line: line
        )
    }

    public static func all<Message>(
        onMessage: @escaping (Behavior<Message>, ActorContext<Message>, Message) throws -> Behavior<Message>,
        onSignal: @escaping (Behavior<Message>, ActorContext<Message>, Signal) throws -> Behavior<Message>,
        file: StaticString = #file, line: UInt = #line) -> Interceptor<Message> {
        return FunctionInterceptor(
            interceptMessage: onMessage,
            interceptSignal: onSignal,
            file: file, line: line
        )
    }
}

/// Interceptor defined by passing interception functions.
/// Useful for small in-line definitions of interceptors which do not need to hold state.
final class FunctionInterceptor<Message>: Interceptor<Message> {

    let onMessage: (Behavior<Message>, ActorContext<Message>, Message) throws -> Behavior<Message>
    let onSignal: (Behavior<Message>, ActorContext<Message>, Signal) throws -> Behavior<Message>

    let file: StaticString
    let line: UInt

    init(interceptMessage onMessage: @escaping (Behavior<Message>, ActorContext<Message>, Message) throws -> Behavior<Message>,
         interceptSignal onSignal: @escaping (Behavior<Message>, ActorContext<Message>, Signal) throws -> Behavior<Message>,
         file: StaticString = #file, line: UInt = #line) {
        self.onSignal = onSignal
        self.onMessage = onMessage
        self.file = file
        self.line = line
    }

    override func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        return try self.onMessage(target, context, message)
    }

    override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        return try self.onSignal(target, context, signal)
    }
}

extension FunctionInterceptor: CustomStringConvertible {
    public var description: String {
        return "FunctionInterceptor(defined at \(self.file):\(self.line)"
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
    func interpretMessage(context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        switch self {
        case let .receiveMessage(recv):          return try recv(message)
        case let .receive(recv):                 return try recv(context, message)
        case let .custom(behavior):              return behavior.receive(context: context, message: message) // TODO rename "custom"
        case let .signalHandling(recvMsg, _):    return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests
        case let .intercept(inner, interceptor): return try interceptor.interceptMessage(target: inner, context: context, message: message)

        case .ignore:                            return .same // ignore message and remain .same

        // illegal to attempt interpreting at the following behaviors (e.g. should have been canonicalized before):
        case .same: return FIXME("Illegal to attempt to interpret message with .same behavior! Behavior should have been canonicalized. This could be a Swift Distributed Actors bug.")
        // illegal to attempt interpreting at the following behaviors (e.g. should have been canonicalized before):
        case .same: return FIXME("Illegal to attempt to interpret message with .same behavior! Behavior should have been canonicalized. This could be a Swift Distributed Actors bug.")
        case .setup: return FIXME("Illegal attempt to interpret message with .setup behavior! This is illegal, behaviors always MUST be canonicalized before interpreting. This could be a Swift Distributed Actors bug.")
        case .failed(let error): return FIXME("Illegal attempt to interpret message with .failed behavior! Reason for original failure was: \(error)")
        case .stopped:                           return FIXME("No message should ever be delivered to a .stopped behavior! This is a mailbox bug.")
        case let .orElse(first, second):
            var nextBehavior = try first.interpretMessage(context: context, message: message)
        }
    }

    /// Attempts interpreting signal using the current behavior, or returns `Behavior.unhandled`
    /// if no `Behavior.signalHandling` was found.
    @inlinable
    func interpretSignal(context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        switch self {
        case .signalHandling(_, let handleSignal):
            return try handleSignal(context, signal)
        case let .intercept(behavior, interceptor):
            return try interceptor.interceptSignal(target: behavior, context: context, signal: signal)
        default:
            // no signal handling installed is semantically equivalent to unhandled
            return .unhandled
        }
    }
}

// MARK: Internal tools to work with Behaviors

/// Internal operations for behavior manipulation
internal extension Behavior {

    /// Applies `interpretMessage` to an iterator of messages, while canonicalizing the behavior after every reduction.
    @inlinable
    func interpretMessages<Iterator: IteratorProtocol>(context: ActorContext<Message>, messages: inout Iterator) throws -> Behavior<Message> where Iterator.Element == Message {
        var currentBehavior: Behavior<Message> = self
        while currentBehavior.isStillAlive() {
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
        switch self {
        case .same:      throw IllegalBehaviorError.notAllowedAsInitial(self)
        case .unhandled: throw IllegalBehaviorError.notAllowedAsInitial(self)
        default: return ()
        }
    }

    func validateAsInitialFatal(file: StaticString = #file, line: UInt = #line) {
        switch self {
        case .same, .unhandled: fatalError("Illegal initial behavior! Attempted to spawn(\(self)) at \(file):\(line)")
        default: return
        }
    }

    /// Shorthand for checking if the current behavior is a `.unhandled`
    @inlinable
    func isUnhandled() -> Bool {
        switch self {
        case .unhandled: return true
        default: return false
        }
    }

    /// Shorthand for checking if the current behavior is a `.stopped` or `.failed`.
    @inlinable
    func isTerminal() -> Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
    }

    /// Shorthand for any [[Behavior]] that is NOT `.stopped`.
    @inlinable
    func isStillAlive() -> Bool {
        return !self.isTerminal()
    }

    /// Ensure that the behavior is in "canonical form", i.e. that all setup behaviors are reduced (run)
    /// before storing the behavior. This process may trigger executing setup(onStart) behaviors.
    @inlinable
    func canonicalize(_ context: ActorContext<Message>, next: Behavior<Message>) throws -> Behavior<Message> {
        // Note: on purpose not implemented as tail recursive function since tail-call elimination is not guaranteed

        var canonical = next
        while true {
            switch canonical {
            case .same:      return self
            case .ignore:    return self
            case .unhandled: return self
            case .custom:    return self
            case .stopped:   return .stopped

            case let .setup(onStart):
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
    // TODO make not recursive perhaps since could blow up on large chain?
    @inlinable func _start(context: ActorContext<Message>) throws -> Behavior<Message> {
        switch self {
        case let .intercept(inner, interceptor):
            return .intercept(behavior: try inner._start(context: context), with: interceptor)
        case .setup(let onStart):
            let unwrapped: Behavior<Message> = try onStart(context)
            return try unwrapped._start(context: context) // since the .setup may contain another .setup
        default:
            return self
        }
    }
}
