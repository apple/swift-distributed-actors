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

import struct NIO.TimeAmount


// MARK: Supervision behaviors

extension Behavior {

    public static func supervise(_ behavior: Behavior<Message>, withStrategy strategy: SupervisionStrategy) -> Behavior<Message> {
        let supervisor: Supervisor<Message> = Supervision.supervisorFor(behavior, strategy)
        return .supervise(behavior, with: supervisor)
    }

    public static func supervise<S: Supervisor<Message>>(_ behavior: Behavior<Message>, with supervisor: S) -> Behavior<Message> {
        return .intercept(behavior: behavior, with: supervisor)
    }
    public static func supervise<S: Supervisor<Message>>(_ behavior: Behavior<Message>, withSupervisor supervisor: S) -> Behavior<Message> {
        return .intercept(behavior: behavior, with: supervisor)
    }

    /// Wrap current behavior with a supervisor.
    /// Fluent-API equivalent to `Behavior.supervise(strategy:)`.
    ///
    /// Supervisor wrappers MAY perform "flattening" of supervision wrapper behaviors, i.e. if attempting to wrap with
    /// the same (or equivalent) supervisor an already supervised behavior, the wrapping may remove one of the wrappers.
    /// For example, `receive` supervised with a `SupervisionStrategy.stop` which would be about to be wrapped in another
    /// `supervise(alreadyStopSupervised, withStrategy: .stop)` would flatten the outer supervisor since it would have no change
    /// in supervision semantics if it were to wrap the behavior with the another layer of the same supervision semantics.
    public func supervisedWith(strategy: SupervisionStrategy) -> Behavior<Message> {
        let supervisor = Supervision.supervisorFor(self, strategy)

        // TODO: much nesting here, we can avoid it if we do .supervise as behavior rather than AN interceptor...
        switch self {
        case .intercept(_, let interceptor): // TODO need to look into inner too?
            if let existingSupervisor = interceptor as? Supervisor<Message> {
                if existingSupervisor.isSameAs(supervisor) {
                    // we perform no wrapping if the existing supervisor already handles everything the new one would.
                    // this allows us to avoid infinitely wrapping supervisors of the same behavior if someone wrote code
                    // returning `self.supervised(...)` inside their behavior.
                    return self
                } else {
                    return .supervise(self, with: supervisor)
                }
            } else {
                return .supervise(self, with: supervisor)
            }

        default:
            return .supervise(self, with: supervisor)
        }
    }

    /// Wrap current behavior with a supervisor.
    /// Fluent-API equivalent to `Behavior.supervise(supervisor:)`.
    public func supervisedWith(supervisor: Supervisor<Message>) -> Behavior<Message> {
        return .supervise(self, with: supervisor)
    }
}

// MARK: Supervision strategies and supervisors

public enum SupervisionStrategy {

    case stop
    case restart(atMost: Int) // TODO: within: TimeAmount etc
    // TODO: how to plug in custom one
}

public struct Supervision {

    public static func supervisorFor<Message>(_ behavior: Behavior<Message>, _ strategy: SupervisionStrategy) -> Supervisor<Message> {
        switch strategy {
        case .stop: return StoppingSupervisor() // TODO: strategy could carry additional configuration
        case .restart: return RestartingSupervisor(initialBehavior: behavior) // TODO: strategy could carry additional configuration
        }
    }

    public enum Failure {
        // TODO: figure out how to represent failures, carry error code, actor path etc I think
        case error(Error)
        case fault(Error)
    }

    /// Thrown in the case of illegal supervision decisions being made, e.g. returning `.same` as decision,
    /// or other situations where supervision failed in some other way.
    public enum DecisionError: Error {
        case illegalDecision(String, handledError: Error, error: Error)
    }

    /// Supervision directives instruct the actor system to apply a specific
    public enum Directive {
        /// TODO: document
        case stop

        /// TODO: document
        case escalate

        /// TODO: document
        case restart

        // TODO: exponential backoff settings, best as config object for easier extension?
        case backoffRestart
    }
}

/// Handles failures that may occur during message (or signal) handling within an actor.
///
/// To implement a custom `Supervisor` you have to override:
///   - either (or both) the `handleMessageFailure` and `handleSignalFailure` methods,
///   - and the `isSameAs` method.
open class Supervisor<Message>: Interceptor<Message> {

    final override func interceptMessage(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        do {
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        } catch {
            let err = error
            context.log.warning("Supervision: Actor has THROWN [\(error)]:\(type(of: error)), handling with \(self)")
            do {
                return try self.handleMessageFailure(context, failure: .error(err)).validatedAsInitial()
            } catch {
                throw Supervision.DecisionError.illegalDecision("Illegal supervision decision detected.", handledError: err, error: error)
            }
        }
    }

    final override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        do {
            return try target.interpretSignal(context: context, signal: signal)
        } catch {
            let err = error
            context.log.warning("Supervision: Actor has THROWN [\(error)]:\(type(of: error)), handling with \(self)")
            do {
                return try self.handleMessageFailure(context, failure: .error(error)).validatedAsInitial()
            } catch {
                throw Supervision.DecisionError.illegalDecision("Illegal supervision decision detected.", handledError: err, error: error)
            }
        }
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that happened during message processing.
    // TODO wording and impl on double-faults
    open func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return undefined()
    }

    /// Handle a failure that occurred during signal processing.
    // TODO wording and impl on double-faults
    open func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return undefined()
    }

    /// Invoked when wrapping (with this `Supervisor`) a `Behavior` that already is supervised.
    ///
    /// The method is always invoked _on_ the existing supervisor with the "new" supervisor.
    /// If this method returns `true` the new supervisor will be dropped and no wrapping will be performed.
    public func isSameAs(_ newSupervisor: Supervisor<Message>) -> Bool {
        return undefined()
    }
}


final class StoppingSupervisor<Message>: Supervisor<Message> {
    override func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return .stopped
    }

    override func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        return .stopped
    }

    override func isSameAs(_ newSupervisor: Supervisor<Message>) -> Bool {
        if newSupervisor is StoppingSupervisor<Message> {
            // we could have more configuration options to check here
            return true
        } else {
            return false
        }
    }
}

final class RestartingSupervisor<Message>: Supervisor<Message> {

    internal let initialBehavior: Behavior<Message>

    private var failures: Int = 0

    public init(initialBehavior behavior: Behavior<Message>) {
        self.initialBehavior = behavior
        super.init()
    }

    override func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        self.failures += 1
        traceLog_Supervision("Supervision: RESTART (\(self.failures)-th time)!!!!!! >>>> \(initialBehavior)") // TODO introduce traceLog for supervision
        // TODO has to modify restart counters here and supervise with modified supervisor
        return try initialBehavior.start(context: context).supervisedWith(supervisor: self)
    }

    override func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        traceLog_Supervision("Supervision: RESTART!!!!!! >>>> \(initialBehavior)")
        return try initialBehavior.start(context: context).supervisedWith(supervisor: self)
    }

    override func isSameAs(_ newSupervisor: Supervisor<Message>) -> Bool {
        if newSupervisor is RestartingSupervisor<Message> {
            // we only check if the target restart behavior is the same; number of restarts is not taken into account
            return true // FIXME: we need to check the other options
            // return self.initialBehavior == s.initialBehavior // FIXME: we need to compare behaviors hm
        } else {
            return false
        }

    }
}
