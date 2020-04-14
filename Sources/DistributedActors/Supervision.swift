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

/// Properties configuring supervision for given actor.
public struct SupervisionProps {
    // internal var supervisionMappings: [ErrorTypeIdentifier: SupervisionStrategy]
    // on purpose stored as list, to keep order in which the supervisors are added as we "scan" from first to last when we handle
    internal var supervisionMappings: [ErrorTypeBoundSupervisionStrategy]

    public static let `default`: SupervisionProps = .init()

    public init() {
        self.supervisionMappings = []
    }

    /// Add another supervision strategy for a specific `Error` type to the supervision chain contained within these props.
    ///
    /// - SeeAlso: The `Supervise.All.*` wildcard failure  type selectors may be used for the `forErrorType` parameter.
    public mutating func add(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) {
        self.supervisionMappings.append(ErrorTypeBoundSupervisionStrategy(failureType: errorType, strategy: strategy))
    }

    /// Non mutating version of `SupervisionProps.add(strategy:forErrorType:)`
    ///
    /// - SeeAlso: The `Supervise.All.*` wildcard failure  type selectors may be used for the `forErrorType` parameter.
    public func adding(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> SupervisionProps {
        var p = self
        p.add(strategy: strategy, forErrorType: errorType)
        return p
    }
}

public extension Props {
    /// Creates a new `Props` appending an supervisor for the selected `Error` type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: error type selector, determining for what type of error the given supervisor should perform its logic.
    static func supervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = Props()
        props.supervise(strategy: strategy, forErrorType: errorType)
        return props
    }

    /// Creates a new `Props` appending an supervisor for the selected failure type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    static func supervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        self.supervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }

    /// Creates a new `Props` appending an supervisor for the selected `Error` type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: error type selector, determining for what type of error the given supervisor should perform its logic.
    func supervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = self
        props.supervise(strategy: strategy, forErrorType: errorType)
        return props
    }

    /// Creates a new `Props` appending an supervisor for the selected failure type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    func supervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        self.supervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }

    /// Adds another supervisor for the selected `Error` type to the chain of existing supervisors in this `Props`.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: failure type selector, working as a "catch all" for the specific types of failures.
    mutating func supervise(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) {
        self.supervision.add(strategy: strategy, forErrorType: errorType)
    }

    /// Adds another supervisor for the selected failure type to the chain of existing supervisors in this `Props`.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    mutating func supervise(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) {
        self.supervise(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }
}

/// Supervision strategies are a way to select and configure pre-defined supervisors.
///
/// **Supervision results in stopping or restarting**
///
/// Most of the following discussion focuses on the `.restart` strategy and its alternative versions and semantics.
/// This is because the only other strategy is `stop`, which is self explanatory: it stops the actor upon any encountered failure.
///
/// **Understanding the failure time period**
///
/// The following visualization may be useful in understanding failure periods and their meaning to the "intensity"
/// of how many restarts are allowed within a failure period:
///
/// ```
/// Assuming supervision with: .restart(atMost: 2, within: .seconds(10))
///
///      fail-per-1  fail-per-2                    failure-period-3
/// TFP: 0123456789  0123456789                       0123456789
///     [x        x][x         ][... no failures ...][x   x  x!!]
///      ^        ^  ^                                ^      ^
///      |        |  |                                |      \ and whenever we hit a 3rd failure within it, we escalate (do not restart, and the actor is stopped)
///      |        |  |                                \ any new failure after a while causes a new failure period
///      |        |  \ another, 3rd in total, failure happens; however it is the beginning of a new failure period; we allow the restart
///      |        \ another failure happens before the end of the period, atMost: 2, so we perform the restart
///      \- a failure begins a failure period of 10 seconds
/// ```
///
/// - Warning:
/// While it is possible to omit the `within` parameter, it has a specific effect which may not often be useful:
/// a `restart` supervision directive without a `within` parameter set effectively means that a given actor is allowed to restart
/// `atMost` times _in total_ (in its entire lifetime). This rarely is a behavior one would desire, however it may sometimes come in handy.
///
/// - SeeAlso: Erlang OTP <a href="http://erlang.org/doc/design_principles/sup_princ.html#maximum-restart-intensity">Maximum Restart Intensity</a>.
///
/// **Restarting with Backoff**
///
/// It is possible to `.restart` a backoff strategy before completing a restart. In this case the passed in `SupervisionStrategy`
/// is invoked and the returned `TimeAmount` is used to suspend the actor for this amount of time, before completing the restart,
/// canonicalizing any `.setup` or similar top-level behaviors and continuing to process messages.
///
/// The following diagram explains how backoff interplays with the lifecycle signals sent to the actor upon a restart,
/// as the prepare (`R`) and complete (`S`) signals of a restart would then occur in different points in time.
///
/// ```
/// Actor: [S     x]R ~~~~~~~[S      x]R~~~~~~~~~[S   ...]
///         ^     ^ ^ ^^^^^^^ ^
///     .setup    | |    |    \- Complete the restart; If present, run any .setup and other nested behaviors, continue running as usual.
///               | |    \- Backoff time before completing the restart, if backoff strategy is set and returns a value.
///               | \- Signals.PreRestart is interpreted by the existing Behavior (in its .onSignal handler, if present)
///               \- "Letting it Crash!"
/// ```
///
/// Backoffs are tremendously useful in building resilient retrying systems, as they allow the avoidance of thundering situations,
/// in case a fault caused multiple actors to fail for the same reason (e.g. the failure of a shared resource).
public enum SupervisionStrategy {
    /// Default supervision strategy applied to all actors, unless a different one is selected in their `Props`.
    ///
    /// Semantically equivalent to not applying any supervision strategy at all, since not applying a strategy
    /// also means that upon encountering a failure the given actor is terminated and all of its watchers are terminated.
    ///
    /// - SeeAlso: `DeathWatch` for discussion about how to be notified about an actor stopping / failing.
    case stop

    /// The restart supervision strategy allowing the supervised actor to be restarted `atMost` times `within` a time period.
    /// In addition, each subsequent restart _may_ be performed after a certain backoff.
    ///
    /// - SeeAlso: The top level `SupervisionStrategy` documentation explores semantics of supervision in more depth.
    ///
    /// **Associated Values**
    ///   - `atMost` number of attempts allowed restarts within a single failure period (defined by the `within` parameter. MUST be > 0).
    ///   - `within` amount of time within which the `atMost` failures are allowed to happen. This defines the so called "failure period",
    ///     which runs from the first failure encountered for `within` time, and if more than `atMost` failures happen in this time amount then
    ///     no restart is performed and the failure is escalated (and the actor terminates in the process).
    ///   - `backoff` strategy to be used for suspending the failed actor for a given (backoff) amount of time before completing the restart.
    ///     The actor's mailbox remains untouched by default, and it would continue processing it from where it left off before the crash;
    ///     the message which caused a failure is NOT processed again. For retrying processing of such higher level mechanisms should be used.
    case restart(atMost: Int, within: TimeAmount?, backoff: BackoffStrategy?) // TODO: would like to remove the `?` and model more properly

    /// WARNING: Purposefully ESCALATES the failure to the parent of the spawned actor, even if it has not watched the child.
    ///
    /// This allows for constructing "fail the parent" even if the parent is not under our control.
    /// This method should not be over used, as normally the parent should decide by itself if it wants to stop
    /// or spawn a replacement child or something else, however sometimes it is useful to allow providers of props
    /// to configure a parent to be torn down when a specific child dies. E.g. when providing workers to a pool,
    /// and we want to enforce the pool dying if only a single child (or a special one) terminates.
    ///
    /// ### Escalating to guardians
    /// Root guardians, such as `/user` or `/system` take care of spawning children when `system.spawn` is invoked.
    /// These guardians normally do not care for the termination of their children, as the `stop` supervision strategy
    /// instructs them to. By spawning a top-level actor, e.g. under the `/user`-guardian and passing in the `.escalate`
    /// strategy, it is possible to escalate failures to the guardians, which in turn will cause the system to terminate.
    ///
    /// This strategy is useful whenever the failure of some specific actor should be considered "fatal to the actor system",
    /// yet we still want to perform a graceful shutdown, rather than an abrupt one (e.g. by calling `exit()`).
    ///
    /// #### Inter-op with `ProcessIsolated`
    /// It is worth pointing out, that escalating failures to root guardians
    case escalate
}

public extension SupervisionStrategy {
    /// Simplified version of `SupervisionStrategy.restart(atMost:within:backoff:)`.
    ///
    /// - SeeAlso: The top level `SupervisionStrategy` documentation explores semantics of supervision in more depth.
    ///
    /// **Providing a `within` time period**
    ///
    /// This version is generally useful for long running actors, which may experience periodic failures, during which time they
    /// should attempt to restart as quickly as possible (without backoff), yet if recovery is not possible and the actor keeps failing
    /// within a designated time amount, it should escalate the failure.
    ///
    /// **Empty `within` failure time period**
    ///
    /// It is possible to pass in `nil` as time period explicitly, which effectively disables the time period.
    /// This is only useful for temporary actors which should terminate after they have completed a specific task,
    /// and the `atMost` allowed failures count is related to this task.
    ///
    /// For example `.restart(atMost: 2)` could be well suited for an actor that should try downloading a web page,
    /// but if it fails twice at the task -- regardless how long it took to fetch/fail, it should be restarted.
    ///
    /// **Associated Values**
    ///   - `atMost` number of attempts allowed restarts within a single failure period (defined by the `within` parameter. MUST be > 0).
    ///   - `within` amount of time within which the `atMost` failures are allowed to happen. This defines the so called "failure period",
    ///     which runs from the first failure encountered for `within` time, and if more than `atMost` failures happen in this time amount then
    ///     no restart is performed and the failure is escalated (and the actor terminates in the process).
    static func restart(atMost: Int, within: TimeAmount?) -> SupervisionStrategy {
        .restart(atMost: atMost, within: within, backoff: nil)
    }
}

internal struct ErrorTypeBoundSupervisionStrategy {
    let failureType: Error.Type
    let strategy: SupervisionStrategy
}

/// Namespace for supervision associated types.
///
/// - SeeAlso: `SupervisionStrategy` for thorough documentation of supervision strategies and semantics.
public struct Supervision {
    /// Internal conversion from supervision props to appropriate (potentially composite) `Supervisor<Message>`.
    internal static func supervisorFor<Message>(_ system: ActorSystem, initialBehavior: Behavior<Message>, props: SupervisionProps) -> Supervisor<Message> {
        func supervisorFor0(failureType: Error.Type, strategy: SupervisionStrategy) -> Supervisor<Message> {
            switch strategy {
            case .restart(let atMost, let within, let backoffStrategy):
                let strategy = RestartDecisionLogic(maxRestarts: atMost, within: within, backoffStrategy: backoffStrategy)
                return RestartingSupervisor(initialBehavior: initialBehavior, restartLogic: strategy, failureType: failureType)
            case .escalate:
                return EscalatingSupervisor(failureType: failureType)
            case .stop:
                return StoppingSupervisor(failureType: failureType)
            }
        }

        switch props.supervisionMappings.count {
        case 0:
            // "no supervisor" is equivalent to a stopping one, this way we can centralize reporting and logging of failures
            return StoppingSupervisor(failureType: Supervise.AllFailures.self)
        case 1:
            let typeBoundStrategy = props.supervisionMappings.first!
            return supervisorFor0(failureType: typeBoundStrategy.failureType, strategy: typeBoundStrategy.strategy)
        default:
            var supervisors: [Supervisor<Message>] = []
            supervisors.reserveCapacity(props.supervisionMappings.count)
            for typeBoundStrategy in props.supervisionMappings {
                let supervisor = supervisorFor0(failureType: typeBoundStrategy.failureType, strategy: typeBoundStrategy.strategy)
                supervisors.append(supervisor)
            }
            return CompositeSupervisor(supervisors: supervisors)
        }
    }

    /// Represents (and unifies) actor failures, i.e. what happens when code running inside an actor throws,
    /// or if such code encounters a fault (such as `fatalError`, divides by zero or causes an out-of-bounds fault
    /// by un-safely accessing an array.
    public enum Failure {
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
    public enum SupervisionError: Error {
        case illegalDecision(String, handledError: Error, error: Error)
    }
}

extension Supervision.Failure: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .fault(let f):
            switch f {
            case let msgProcessingErr as MessageProcessingFailure:
                return "fault(\(msgProcessingErr))"
            default:
                return "fault(\(f))"
            }
        case .error(let err):
            return "error(\(err))"
        }
    }

    public var debugDescription: String {
        switch self {
        case .fault(let f):
            switch f {
            case let msgProcessingErr as MessageProcessingFailure:
                return "fault(\(String(reflecting: msgProcessingErr))"
            default:
                return "fault(\(f))"
            }
        case .error(let err):
            return "error(\(err))"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Phantom types for registering supervisors

public enum Supervise {
    /// Supervision failure "catch all" selectors.
    /// By configuring supervision with one of the following you may configure a supervisor to catch only a specific
    /// type of failures (e.g. only swift `Error`s or only faults).
    ///
    /// See also supervision overloads which accept an `Error.Type` which allows you to specifically select an error type to supervise.
    public enum All {
        case errors
        case faults
        case failures
    }

    // MARK: Phantom types for registering supervisors

    internal static func internalErrorTypeFor(selector: Supervise.All) -> Error.Type {
        switch selector {
        case .errors: return AllErrors.self
        case .faults: return AllFaults.self
        case .failures: return AllFailures.self
        }
    }

    internal enum AllErrors: Error {}

    internal enum AllFaults: Error {}

    internal enum AllFailures: Error {}
}

/// Used in `Supervisor` to determine what type of processing caused the failure
///
/// - start: failure happened during actor (re-)starting, for example an error was thrown in an initial `.setup`
/// - message: failure happened during message processing
/// - signal: failure happened during signal processing
/// - closure: failure happened during closure processing
@usableFromInline
internal enum ProcessingType {
    case start
    case message
    case signal
    case closure
    case continuation
    case subMessage
}

@usableFromInline
internal enum ProcessingAction<Message: Codable> {
    case start
    case message(Message)
    case signal(Signal)
    case closure(ActorClosureCarry)
    case continuation(() throws -> Behavior<Message>) // TODO: make it a Carry type for better debugging
    case subMessage(SubMessageCarry)
}

extension ProcessingAction {
    @usableFromInline
    var type: ProcessingType {
        switch self {
        case .start: return .start
        case .message: return .message
        case .signal: return .signal
        case .closure: return .closure
        case .continuation: return .continuation
        case .subMessage: return .subMessage
        }
    }
}

/// Handles failures that may occur during message (or signal) handling within an actor.
///
/// Currently not for user extension.
@usableFromInline
internal class Supervisor<Message: Codable> {
    @usableFromInline
    typealias Directive = SupervisionDirective<Message>

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        traceLog_Supervision("CALL WITH \(target) @@@@ [\(message)]:\(type(of: message))")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .message(message))
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        traceLog_Supervision("INTERCEPT SIGNAL APPLY: \(target) @@@@ \(signal)")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .signal(signal))
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, closure: ActorClosureCarry) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE: \(target)")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .closure(closure))
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, subMessage: SubMessageCarry) throws -> Behavior<Message> {
        traceLog_Supervision("INTERPRETING SUB MESSAGE: \(target)")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .subMessage(subMessage))
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, closure: @escaping () throws -> Behavior<Message>) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE: \(target)")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .continuation(closure))
    }

    @inlinable
    internal final func startSupervised(target: Behavior<Message>, context: ActorContext<Message>) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING START")
        return try self.interpretSupervised0(target: target, context: context, processingAction: .start)
    }

    /// Implements all directives, which supervisor implementations may yield to instruct how we should (if at all) restart an actor.
    @inlinable
    final func interpretSupervised0(target: Behavior<Message>, context: ActorContext<Message>, processingAction: ProcessingAction<Message>) throws -> Behavior<Message> {
        try self.interpretSupervised0(target: target, context: context, processingAction: processingAction, nFoldFailureDepth: 1) // 1 since we already have "one failure"
    }

    @inlinable
    final func interpretSupervised0(target: Behavior<Message>, context: ActorContext<Message>, processingAction: ProcessingAction<Message>, nFoldFailureDepth: Int) throws -> Behavior<Message> {
        do {
            switch processingAction {
            case .start:
                return try target.start(context: context)

            case .message(let message):
                return try target.interpretMessage(context: context, message: message)
            case .signal(let signal):
                return try target.interpretSignal(context: context, signal: signal)

            case .closure(let closure):
                try closure.function()
                return .same
            case .continuation(let continuation):
                return try continuation()
            case .subMessage(let carry):
                guard let subFunction = context.subReceive(identifiedBy: carry.identifier) else {
                    fatalError("BUG! Received sub message [\(carry.message)]:\(type(of: carry.message)) for unknown identifier \(carry.identifier) on address \(carry.subReceiveAddress). Please report this on the issue tracker.")
                }

                return try subFunction(carry)
            }
        } catch {
            return try self.handleError(context: context, target: target, processingAction: processingAction, error: error)
        }
    }

    @usableFromInline
    func handleError(context: ActorContext<Message>, target: Behavior<Message>, processingAction: ProcessingAction<Message>, error: Error) throws -> Behavior<Message> {
        var errorToHandle = error
        // The following restart loop exists to support interpreting `PreRestart` and `Start` signal interpretation failures;
        // If the actor fails during restarting, this failure becomes the new failure reason, and we supervise this failure
        // this allows "try again a few times restarts" to happen even if the fault occurs in starting the actor (e.g. opening a file or obtaining some resource failing).
        //
        // This "restart loop" matters only for:
        // - `.restartImmediately` decisions which result in throwing during `_restartPrepare` OR `_restartComplete`,
        // - or `.restartDelayed` decisions which result in throwing during `_restartPrepare`.
        //
        // Since this is a special situation somewhat, in which the tight crash loop could consume considerable resources (and maybe never recover),
        // we limit the number of times the restart is attempted

        do {
            try context._downcastUnsafe.deferred.invokeAllAfterReceiveFailed()
        } catch {
            context.log.warning("Failed while invoking deferred behaviors after failed receive. \(error)")
            errorToHandle = error
        }

        repeat {
            switch processingAction {
            case .closure(let closure):
                context.log.warning("Actor has THROWN [\(errorToHandle)]:\(type(of: errorToHandle)) while interpreting [closure defined at \(closure.file):\(closure.line)], handling with \(self.descriptionForLogs)")
            default:
                context.log.warning("Actor has THROWN [\(errorToHandle)]:\(type(of: errorToHandle)) while interpreting \(processingAction), handling with \(self.descriptionForLogs)")
            }

            let directive: Directive
            do {
                directive = try self.handleFailure(context, target: target, failure: .error(errorToHandle), processingType: processingAction.type)
            } catch {
                // An error was thrown by our Supervisor logic while handling the failure, this is a bug and thus we crash hard
                throw Supervision.SupervisionError.illegalDecision("Illegal supervision decision detected.", handledError: errorToHandle, error: error)
            }

            do {
                switch directive {
                case .stop:
                    return .stop(reason: .failure(.error(error)))

                case .escalate(let failure):
                    return context._downcastUnsafe._escalate(failure: failure)

                case .restartImmediately(let replacement):
                    try context._downcastUnsafe._restartPrepare()
                    return try context._downcastUnsafe._restartComplete(with: replacement)

                case .restartDelayed(let delay, let replacement):
                    try context._downcastUnsafe._restartPrepare()
                    return SupervisionRestartDelayedBehavior.after(delay: delay, with: replacement)
                }
            } catch {
                errorToHandle = error // the error captured from restarting is now the reason why we are failing, and should be passed to the supervisor
                continue // by now supervising the errorToHandle which has just occurred
            }
        } while true // the only way to break out of here is succeeding to interpret `directive` OR supervisor giving up (e.g. max nr of restarts being exhausted)
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that happened during processing.
    ///
    /// The returned `SupervisionDirective` will be interpreted appropriately.
    open func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        undefined()
    }

    /// Implement and return `true` if this supervisor can handle the failure or not.
    /// If `false` is returned and other supervisors are present, they will be tied in order, until a supervisor which
    /// can handle the failure is found, or if no such supervisor exists the failure will cause the actor to crash (as expected).
    open func canHandle(failure: Supervision.Failure) -> Bool {
        undefined()
    }

    /// Invoked when wrapping (with this `Supervisor`) a `Behavior` that already is supervised.
    ///
    /// The method is always invoked _on_ the existing supervisor with the "new" supervisor.
    /// If this method returns `true` the new supervisor will be dropped and no wrapping will be performed.
    func isSame(as other: Supervisor<Message>) -> Bool {
        undefined()
    }

    var descriptionForLogs: String {
        "\(type(of: self))"
    }
}

/// Supervisor equivalent to not having supervision enabled, since stopping is the default behavior of failing actors.
/// At the same time, it may be useful to sometimes explicitly specify that for some type of error we want to stop
/// (e.g. when used with composite supervisors, which restart for all failures, yet should not do so for some specific type of error).
final class StoppingSupervisor<Message: Codable>: Supervisor<Message> {
    internal let failureType: Error.Type

    internal init(failureType: Error.Type) {
        self.failureType = failureType
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        if failure.shouldBeHandled(bySupervisorHandling: self.failureType) {
            // TODO: matters perhaps only for metrics where we'd want to "please count this specific type of error" so leaving this logic as-is
            return .stop
        } else {
            return .stop
        }
    }

    override func isSame(as other: Supervisor<Message>) -> Bool {
        if let other = other as? StoppingSupervisor<Message> {
            return self.failureType == other.failureType
        } else {
            return false
        }
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }

    override var descriptionForLogs: String {
        "[.stop] supervision strategy"
    }
}

/// Escalates failure to parent, while failing the current actor.
final class EscalatingSupervisor<Message: Codable>: Supervisor<Message> {
    internal let failureType: Error.Type

    internal init(failureType: Error.Type) {
        self.failureType = failureType
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        if failure.shouldBeHandled(bySupervisorHandling: self.failureType) {
            return .escalate(failure)
        } else {
            return .stop
        }
    }

    override func isSame(as other: Supervisor<Message>) -> Bool {
        if let other = other as? EscalatingSupervisor<Message> {
            return self.failureType == other.failureType
        } else {
            return false
        }
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }

    override var descriptionForLogs: String {
        "[.escalate<\(self.failureType)>] supervision strategy"
    }
}

// There are a few ways we could go about implementing this, we currently do a simple scan for "first one that handles",
// which should be quite good enough esp. since we expect the supervisors to be usually not more than just a few.
//
// The scan also makes implementing the "catch" all types `Supervision.AllFailures` etc simpler rather than having to search
// the underlying map for the catch all handlers as well as the specific error.
final class CompositeSupervisor<Message: Codable>: Supervisor<Message> {
    private let supervisors: [Supervisor<Message>]

    init(supervisors: [Supervisor<Message>]) {
        assert(supervisors.count > 1, "There is no need to use a composite supervisor if only one supervisor is passed in. Consider this a Swift Distributed Actors bug.")
        self.supervisors = supervisors
        super.init()
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        for supervisor in self.supervisors {
            if supervisor.canHandle(failure: failure) {
                return try supervisor.handleFailure(context, target: target, failure: failure, processingType: processingType)
            }
        }
        return .stop
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        self.supervisors.contains {
            $0.canHandle(failure: failure)
        }
    }
}

/// Instructs the mailbox to take specific action, reflecting wha the supervisor intends to do with the actor.
///
/// - SeeAlso: `Supervisor.handleFailure`
@usableFromInline
internal enum SupervisionDirective<Message: Codable> {
    /// Directs mailbox to directly stop processing.
    case stop
    /// Directs mailbox to prepare AND complete a restart immediately.
    case restartImmediately(Behavior<Message>)
    /// Directs mailbox to prepare a restart after a delay.
    case restartDelayed(TimeAmount, Behavior<Message>)
    /// Directs the mailbox to immediately fail and stop processing.
    /// Failures should "bubble up".
    case escalate(Supervision.Failure)
}

internal enum SupervisionDecision {
    case restartImmediately
    case restartBackoff(delay: TimeAmount) // could also configure "drop messages while restarting" etc
    case escalate
    case stop
}

/// Encapsulates logic around when a restart is allowed, i.e. tracks the deadlines of failure periods.
internal struct RestartDecisionLogic {
    let maxRestarts: Int
    let within: TimeAmount?
    var backoffStrategy: BackoffStrategy?

    // counts how many times we failed during the "current" `within` period
    private var restartsWithinCurrentPeriod: Int = 0
    private var restartsPeriodDeadline: Deadline = Deadline.distantPast

    init(maxRestarts: Int, within: TimeAmount?, backoffStrategy: BackoffStrategy?) {
        precondition(maxRestarts > 0, "RestartStrategy.maxRestarts MUST be > 0")
        self.maxRestarts = maxRestarts
        if let failurePeriodTime = within {
            precondition(failurePeriodTime.nanoseconds > 0, "RestartStrategy.within MUST be > 0. For supervision without time bounds (i.e. absolute count of restarts allowed) use `.restart(:atMost)` instead.")
            self.within = failurePeriodTime
        } else {
            // if within was not set, we treat is as if "no time limit", which we mimic by a Deadline far far away in time
            self.restartsPeriodDeadline = .distantFuture
            self.within = nil
        }
        self.backoffStrategy = backoffStrategy
    }

    /// Increment the failure counter (and possibly reset the failure period deadline).
    ///
    /// MUST be called whenever a failure reaches a supervisor.
    mutating func recordFailure() -> SupervisionDecision {
        if self.restartsPeriodDeadline.isOverdue() {
            // thus the next period starts, and we will start counting the failures within that time window anew

            // ! safe, because we are guaranteed to never exceed the .distantFuture deadline that is set when within is nil
            let failurePeriodTimeAmount = self.within!
            self.restartsPeriodDeadline = .fromNow(failurePeriodTimeAmount)
            self.restartsWithinCurrentPeriod = 0
        }
        self.restartsWithinCurrentPeriod += 1

        if self.periodHasTimeLeft, self.isWithinMaxRestarts {
            guard self.backoffStrategy != nil else {
                return .restartImmediately
            }

            // so the backoff strategy _is_ set, and a `nil` from it would mean "stop restarting"
            if let backoffAmount = self.backoffStrategy?.next() {
                return .restartBackoff(delay: backoffAmount)
            } else {
                // we stop since the strategy decided we've been trying again enough and it is time to stop
                // TODO: could be configurable to escalate once restarts exhausted
                return .stop
            }

        } else {
            // e.g. total time within which we are allowed to back off has been exceeded etc
            // TODO: could be configurable to escalate once restarts exhausted
            return .stop
        }
    }

    private var periodHasTimeLeft: Bool {
        self.restartsPeriodDeadline.hasTimeLeft(until: .now())
    }

    private var isWithinMaxRestarts: Bool {
        self.restartsWithinCurrentPeriod <= self.maxRestarts
    }

    /// Human readable description of how the status of the restart supervision strategy
    var remainingRestartsDescription: String {
        var s = "\(self.restartsWithinCurrentPeriod) of \(self.maxRestarts) max restarts consumed"
        if let within = self.within {
            s += ", within: \(within.prettyDescription)"
        }
        return s
    }
}

final class RestartingSupervisor<Message: Codable>: Supervisor<Message> {
    internal let failureType: Error.Type

    internal let initialBehavior: Behavior<Message>

    private var restartDecider: RestartDecisionLogic

    public init(initialBehavior behavior: Behavior<Message>, restartLogic: RestartDecisionLogic, failureType: Error.Type) {
        self.initialBehavior = behavior
        self.restartDecider = restartLogic
        self.failureType = failureType
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        let decision: SupervisionDecision = self.restartDecider.recordFailure()

        guard failure.shouldBeHandled(bySupervisorHandling: self.failureType) else {
            traceLog_Supervision("ESCALATE from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(self.initialBehavior)")

            return .stop
        }

        switch decision {
        case .stop:
            traceLog_Supervision("STOP from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(self.initialBehavior)")

            return .stop

        case .escalate:
            traceLog_Supervision("ESCALATE from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(self.initialBehavior)")

            return .escalate(failure)

        case .restartImmediately:
            // TODO: make proper .ordinalString function
            traceLog_Supervision("RESTART from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(self.initialBehavior)")
            // TODO: has to modify restart counters here and supervise with modified supervisor

            return .restartImmediately(self.initialBehavior)

        case .restartBackoff(let delay):
            traceLog_Supervision("RESTART BACKOFF(\(delay.prettyDescription)) from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(self.initialBehavior)")

            return .restartDelayed(delay, self.initialBehavior)
        }
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }

    // TODO: complete impl
    public override func isSame(as other: Supervisor<Message>) -> Bool {
        other is RestartingSupervisor<Message>
    }

    override var descriptionForLogs: String {
        "[.restart(\(self.restartDecider))] supervision strategy"
    }
}

/// Behavior used to suspend after a `restartPrepare` has been issued by an `restartDelayed`.
@usableFromInline
internal enum SupervisionRestartDelayedBehavior<Message: Codable> {
    @usableFromInline
    internal struct WakeUp {}

    @usableFromInline
    static func after(delay: TimeAmount, with replacement: Behavior<Message>) -> Behavior<Message> {
        .setup { context in
            context.timers._startResumeTimer(key: TimerKey("restartBackoff", isSystemTimer: true), delay: delay, resumeWith: WakeUp())

            return .suspend { (result: Result<WakeUp, Error>) in
                traceLog_Supervision("RESTART BACKOFF TRIGGER")
                switch result {
                case .failure(let error):
                    context.log.error("Failed result during backoff restart. Error was: \(error). Forcing actor to crash.")
                    throw error
                case .success:
                    // _downcast safe, we know this may only ever run for a local ref, thus it will definitely be an ActorCell
                    return try context._downcastUnsafe._restartComplete(with: replacement)
                }
            }
        }
    }
}

extension RestartingSupervisor: CustomStringConvertible {
    public var description: String {
        // TODO: don't forget to include config in string repr once we do it
        "RestartingSupervisor(initialBehavior: \(self.initialBehavior), strategy: \(self.restartDecider), canHandle: \(self.failureType))"
    }
}

private extension Supervision.Failure {
    func shouldBeHandled(bySupervisorHandling handledType: Error.Type) -> Bool {
        let supervisorHandlesEverything = handledType == Supervise.AllFailures.self

        func matchErrorTypes0() -> Bool {
            switch self {
            case .error(let error):
                return handledType == Supervise.AllErrors.self || handledType == type(of: error)
            case .fault(let errorRepr):
                return handledType == Supervise.AllFaults.self || handledType == type(of: errorRepr)
            }
        }

        return supervisorHandlesEverything || matchErrorTypes0()
    }
}
