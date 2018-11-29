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

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    case receiveMessage(_ handle: (Message) throws -> Behavior<Message>) // TODO: make them throws?

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    /// Additionally exposes `ActorContext` which can be used to e.g. log messages, spawn child actors etc.
    case receive(_ handle: (ActorContext<Message>, Message) throws -> Behavior<Message>) // TODO: make them throws?

    // TODO: receiveExactly(_ expected: Message, orElse: Behavior<Message> = /* .ignore */, atMost = /* 5.seconds */)

    // TODO: above is receiveMessage(M -> B)
    // TODO: we need receive((Context, M) -> B) as well, leaving it for later

    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// This can be used to obtain the context, logger or perform actions right when the actor starts
    /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
    case setup(onStart: (ActorContext<Message>) throws -> Behavior<Message>)

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

    /// Allows handling messages
    indirect case signalHandling(handleMessage: Behavior<Message>,
                                 handleSignal: (ActorContext<Message>, SystemMessage) throws -> Behavior<Message>)

    // TODO internal and should not be used by people (likely we may need to change Behaviors away from an enum to allow such things?
    indirect case supervised(supervisor: AnyReceivesSystemMessages, behavior: Behavior<Message>)

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

// MARK: Behavior combinators

extension Behavior {

    public func orElse(_ alternativeBehavior: Behavior<Message>) -> Behavior<Message> {
        return TODO("Not implemented yet:: orElse")
    }

    public func receiveSignal(_ handle: @escaping (ActorContext<Message>, SystemMessage) -> Behavior<Message>) -> Behavior<Message> {
        return Behavior<Message>.signalHandling(handleMessage: self, handleSignal: handle)
    }

    public static func receiveSignal(_ handle: @escaping (ActorContext<Message>, SystemMessage) -> Behavior<Message>) -> Behavior<Message> {
        return Behavior<Message>.signalHandling(handleMessage: .unhandled, handleSignal: handle)
    }
}


public enum IllegalBehaviorError<M>: Error {
    /// Some behaviors, like `.same` and `.unhandled` are not allowed to be used as initial behaviors.
    /// See their individual documentation for the rationale why that is so.
    indirect case notAllowedAsInitial(_ behavior: Behavior<M>)
}


open class ActorBehavior<Message> {
    open func receive(context: ActorContext<Message>, message: Message) -> Behavior<Message> {
        return undefined(hint: "MUST override receive(context:message:) when extending ActorBehavior")
    }

    open func receiveSignal(context: ActorContext<Message>, signal: Signal) -> Behavior<Message> {
        return .unhandled
    }
}

// MARK: Internal tools to work with Behaviors

/// Internal operations for behavior manipulation
internal extension Behavior {
    // TODO: was thinking to make it a class since then we could "hide it more" from users... Do we need to though? they can't call them anyway -- ktoso

    /// Interpret the passed in message.
    ///
    /// Note: The returned behavior MUST be [[Behavior.canonicalize]]-ed in the vast majority of cases.
    // Implementation note: We don't do so here automatically in order to keep interpretations transparent and testable.
    @inlinable
    internal func interpretMessage(context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        switch self {
        case let .receiveMessage(recv):       return try recv(message)
        case let .receive(recv):              return try recv(context, message)
        case .ignore:                         return .same // ignore message and remain .same
        case let .custom(behavior):           return behavior.receive(context: context, message: message)
        case let .signalHandling(recvMsg, _): return try recvMsg.interpretMessage(context: context, message: message) // TODO: should we keep the signal handler even if not .same? // TODO: more signal handling tests
        case .stopped:                        return FIXME("No message should ever be delivered to a .stopped behavior! This is a mailbox bug.")
        default:                              return TODO("NOT IMPLEMENTED YET: handling of: \(self)")
        }
    }

    @inlinable
    internal func interpretMessages<Iterator: IteratorProtocol>(context: ActorContext<Message>, messages: inout Iterator) throws -> Behavior<Message> where Iterator.Element == Message {
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
    internal func isUnhandled() -> Bool {
        switch self {
        case .unhandled: return true
        default: return false
        }
    }

    /// Shorthand for checking if the current behavior is a `.stopped`.
    @inlinable
    internal func isStopped() -> Bool {
        switch self {
        case .stopped: return true
        default: return false
        }
    }

    /// Shorthand for any [[Behavior]] that is NOT `.stopped`.
    @inlinable
    internal func isStillAlive() -> Bool {
        return !self.isStopped()
    }

    /// Ensure that the behavior is in "canonical form", i.e. that all setup behaviors are reduced (run)
    /// before storing the behavior. This process may trigger executing setup(onStart) behaviors.
    @inlinable
    internal func canonicalize(_ context: ActorContext<Message>, next: Behavior<Message>) throws -> Behavior<Message> {
        // Note: on purpose not implemented as tail recursive function since tail-call elimination is not guaranteed

        var canonical = next
        while true {
            switch canonical {
            case .same:               return self
            case .ignore:             return self
            case .unhandled:          return self
            case .custom:             return self
            case .stopped:            return .stopped
            case let .setup(onStart): canonical = try onStart(context)
            default:                  return canonical
            }
        }

    }
}
