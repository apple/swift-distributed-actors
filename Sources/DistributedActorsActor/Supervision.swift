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

    // MARK: Supervise with SupervisionStrategy

    /// Wrap current behavior with a supervisor.
    ///
    /// Supervisor wrappers MAY perform "flattening" of supervision wrapper behaviors, i.e. if attempting to wrap with
    /// the same (or equivalent) supervisor an already supervised behavior, the wrapping may remove one of the wrappers.
    /// For example, `receive` supervised with a `SupervisionStrategy.stop` which would be about to be wrapped in another
    /// `supervise(alreadyStopSupervised, withStrategy: .stop)` would flatten the outer supervisor since it would have no change
    /// in supervision semantics if it were to wrap the behavior with the another layer of the same supervision semantics.
    ///
    /// SeeAlso:
    ///  - `supervisedWith(strategy)`
    public static func supervise(_ behavior: Behavior<Message>, withStrategy strategy: SupervisionStrategy) -> Behavior<Message> {
        let supervisor: Supervisor<Message> = Supervision.supervisorFor(behavior, strategy)
        return .supervise(behavior, withSupervisor: supervisor)
    }

    /// Wrap current behavior with a supervisor.
    /// Fluent-API equivalent to `Behavior.supervise(strategy:)`.
    ///
    /// Supervisor wrappers MAY perform "flattening" of supervision wrapper behaviors, i.e. if attempting to wrap with
    /// the same (or equivalent) supervisor an already supervised behavior, the wrapping may remove one of the wrappers.
    /// For example, `receive` supervised with a `SupervisionStrategy.stop` which would be about to be wrapped in another
    /// `supervise(alreadyStopSupervised, withStrategy: .stop)` would flatten the outer supervisor since it would have no change
    /// in supervision semantics if it were to wrap the behavior with the another layer of the same supervision semantics.
    /// SeeAlso:
    ///  - `supervise(_:withStrategy)`
    public func supervised(withStrategy strategy: SupervisionStrategy) -> Behavior<Message> {
        let supervisor = Supervision.supervisorFor(self, strategy)
        return .supervise(self, withSupervisor: supervisor)
    }

    // MARK: Internal API: Supervise with Supervisors

    /// INTERNAL API: We do not want to expose the full power of supervision with arbitrary behavior substitution to users unless we know for sure it is needed.
    ///
    /// This API is a more powerful version of supervision which is able to accept (potentially stateful) supervisor implementations.
    /// Those implementations MAY contain counters, timers and logic which determines how to handle a failure.
    ///
    /// Swift Distributed Actors provides the most important supervisors out of the box, which are selected and configured using supervision strategies.
    /// Uses are requested to use those instead, and if they seem lacking some feature, requests for specific features should be opened first.
    internal static func supervise<S: Supervisor<Message>>(_ behavior: Behavior<Message>, withSupervisor supervisor: S) -> Behavior<Message> {
        // TODO: much nesting here, we can avoid it if we do .supervise as behavior rather than AN interceptor...
        switch behavior {
        case .intercept(_, let interceptor): // TODO need to look into inner too?
            let existingSupervisor: Supervisor<Message>? = interceptor as? Supervisor<Message>
            if existingSupervisor?.isSameAs(supervisor) ?? false {
                // we perform no wrapping if the existing supervisor already handles everything the new one would.
                // this allows us to avoid infinitely wrapping supervisors of the same behavior if someone wrote code
                // returning `behavior.supervised(...)` inside their behavior.
                return behavior
            }
        default:
            break
        }

        return .intercept(behavior: behavior, with: supervisor)
    }

    /// INTERNAL API: We do not want to expose the full power of supervision with arbitrary behavior substitution to users unless we know for sure it is needed.
    /// Wrap current behavior with a supervisor.
    /// Fluent-API equivalent to `Behavior.supervise(supervisor:)`.
    internal func supervised(supervisor: Supervisor<Message>) -> Behavior<Message> {
        return .supervise(self, withSupervisor: supervisor)
    }
}

// MARK: Supervision strategies and supervisors

/// Supervision strategies are a way to select and configure pre-defined supervisors included in Swift Distributed Actors.
///
/// These supervisors implement basic supervision patterns and can be combined by wrapping behaviors in multiple supervisors,
/// e.g. by first attempting to restart immediately a few times, and then resorting to back off supervision etc.
///
/// In most cases it is not necessary to apply the `.stop` strategy, as this is the default behavior of actors with
/// when no supervisors are present.
public enum SupervisionStrategy {
    case stop
    case restart(atMost: Int) // TODO: within: TimeAmount etc
}

public struct Supervision {

    public static func supervisorFor<Message>(_ behavior: Behavior<Message>, _ strategy: SupervisionStrategy) -> Supervisor<Message> {
        switch strategy {
        case .stop: return StoppingSupervisor() // TODO: strategy could carry additional configuration
        case .restart: return RestartingSupervisor(initialBehavior: behavior) // TODO: strategy could carry additional configuration
        }
    }

    /// Represents (and unifies) actor failures, i.e. what happens when code running inside an actor throws,
    /// or if such code encounters a fault (such as `fatalError`, divides by zero or causes an out-of-bounds fault
    /// by un-safely accessing an array.
    public enum Failure {
        // TODO: figure out how to represent failures, carry error code, actor path etc I think
        /// The failure was caused by the actor throwing during its execution.
        /// The carried `Error` is the error that the actor has thrown.
        case error(Error)
        /// The failure was caused by the actor encountering a fault.
        /// The fault (i.e. error code) has been represented as an `Error` and carried inside this fault case.
        ///
        /// Do note that - by design - not all faults will be caught by supervision; some faults are considered so-called
        /// "fatal faults", and will not be offered to supervisors.
        case fault(Error)
    }

    /// Thrown in the case of illegal supervision decisions being made, e.g. returning `.same` as decision,
    /// or other situations where supervision failed in some other way.
    public enum DecisionError: Error {
        case illegalDecision(String, handledError: Error, error: Error)
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
            pprint("INTERCEPT MSG APPLY: \(target) @@@@ \(message)")
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        } catch {
            let err = error
            context.log.warning("Supervision: Actor has THROWN [\(err)]:\(type(of: err)) while interpreting message, handling with \(self)")
            do {
                return try self.handleMessageFailure(context, failure: .error(err)).validatedAsInitial()
            } catch {
                throw Supervision.DecisionError.illegalDecision("Illegal supervision decision detected.", handledError: err, error: error)
            }
        }
    }

    final override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        do {
            pprint("INTERCEPT SIGNAL APPLY: \(target) @@@@ \(signal)")
            return try target.interpretSignal(context: context, signal: signal)
        } catch {
            let err = error
            context.log.warning("Supervision: Actor has THROWN [\(error)]:\(type(of: error)) while interpreting signal, handling with \(self)")
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

    // TODO complete impl
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

    // TODO Implement respecting restart(atMost restarts: Int) !!!

    public init(initialBehavior behavior: Behavior<Message>) {
        self.initialBehavior = behavior
        super.init()
    }

    override func handleMessageFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        self.failures += 1
        // TODO make proper .ordinalString function
        traceLog_Supervision("Supervision: RESTART from message (\(self.failures)-th time), failure was: \(failure)! >>>> \(initialBehavior)") // TODO introduce traceLog for supervision
        // TODO has to modify restart counters here and supervise with modified supervisor

        (context as! ActorCell<Message>).stopAllChildren() // FIXME this must be doable without casting

        return try initialBehavior.start(context: context).supervised(supervisor: self)
    }

    override func handleSignalFailure(_ context: ActorContext<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        self.failures += 1
        traceLog_Supervision("Supervision: RESTART form signal (\(self.failures)-th time), failure was: \(failure)! >>>> \(initialBehavior)")
        return try initialBehavior.start(context: context).supervised(supervisor: self)
    }

    // TODO complete impl
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
