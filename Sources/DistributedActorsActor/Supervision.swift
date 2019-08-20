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
    static func addingSupervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = Props()
        props.addSupervision(strategy: strategy, forErrorType: errorType)
        return props
    }
    /// Creates a new `Props` appending an supervisor for the selected failure type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    static func addingSupervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        return addingSupervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }

    /// Creates a new `Props` appending an supervisor for the selected `Error` type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: error type selector, determining for what type of error the given supervisor should perform its logic.
    func addingSupervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = self
        props.addSupervision(strategy: strategy, forErrorType: errorType)
        return props
    }
    /// Creates a new `Props` appending an supervisor for the selected failure type, useful for setting a few options in-line when spawning actors.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    func addingSupervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        return self.addingSupervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }
    /// Adds another supervisor for the selected `Error` type to the chain of existing supervisors in this `Props`.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: failure type selector, working as a "catch all" for the specific types of failures.
    mutating func addSupervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) {
        self.supervision.add(strategy: strategy, forErrorType: errorType)
    }
    /// Adds another supervisor for the selected failure type to the chain of existing supervisors in this `Props`.
    ///
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    mutating func addSupervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) {
        self.addSupervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
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
    case restart(atMost: Int, within: TimeAmount?, backoff: BackoffStrategy?) // TODO would like to remove the `?` and model more properly
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
        return .restart(atMost: atMost, within: within, backoff: nil)
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
            case let .restart(atMost, within, backoffStrategy):
                let strategy = RestartDecisionLogic(maxRestarts: atMost, within: within, backoffStrategy: backoffStrategy)
                return RestartingSupervisor(initialBehavior: initialBehavior, restartLogic: strategy, failureType: failureType)
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
    public enum DecisionError: Error {
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
/// - message: failure happened during message processing
/// - signal: failure happened during signal processing
/// - closure: failure happened during closure processing
@usableFromInline
internal enum ProcessingType {
    case message
    case signal
    case closure
    case continuation
}

/// Handles failures that may occur during message (or signal) handling within an actor.
///
/// Currently not for user extension.
@usableFromInline
internal class Supervisor<Message> {

    typealias Directive = SupervisionDirective<Message>

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        traceLog_Supervision("CALL WITH \(target) @@@@ [\(message)]:\(type(of: message))")
        return try self.interpretSupervised0(target: target, context: context, processingType: .message) {
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        }
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        traceLog_Supervision("INTERCEPT SIGNAL APPLY: \(target) @@@@ \(signal)")
        return try self.interpretSupervised0(target: target, context: context, processingType: .signal) {
            return try target.interpretSignal(context: context, signal: signal)
        }
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, closure: () throws -> Void) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE: \(target)")
        return try self.interpretSupervised0(target: target, context: context, processingType: .closure) {
            try closure()
            return .same
        }
    }

    @inlinable
    internal final func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, closure: () throws -> Behavior<Message>) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE: \(target)")
        return try self.interpretSupervised0(target: target, context: context, processingType: .continuation) {
            return try closure()
        }
    }

    /// Implements all directives, which supervisor implementations may yield to instruct how we should (if at all) restart an actor.
    @usableFromInline
    final func interpretSupervised0(target: Behavior<Message>, context: ActorContext<Message>, processingType: ProcessingType, closure: () throws -> Behavior<Message>) throws -> Behavior<Message> {
        do {
            return try closure()
        } catch {
            let err = error
            context.log.warning("Actor has THROWN [\(error)]:\(type(of: error)) while interpreting \(processingType), handling with \(self)")
            do {
                let directive: Directive = try self.handleFailure(context, target: target, failure: .error(error), processingType: processingType)
                switch directive {
                case .stop:
                    return .stopped(reason: .failure(.error(error)))

                case .escalate(let failure):
                    // TODO this is not really escalating (yet)
                    return .stopped(reason: .failure(failure))

                case .restartImmediately(let replacement):
                    // FIXME: should this not implement the same "call restartPrepare() / restartComplete()"?
                    try context._downcastUnsafe._restartPrepare()
                    return try context._downcastUnsafe._restartComplete(with: replacement)

                case .restartDelayed(let delay, let replacement):
                    try context._downcastUnsafe._restartPrepare()

                    return SupervisionRestartDelayedBehavior.after(delay: delay, with: replacement)
                }
            } catch {
                throw Supervision.DecisionError.illegalDecision("Illegal supervision decision detected.", handledError: err, error: error)
            }
        }
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that happened during processing.
    ///
    /// The returned `SupervisionDirective` will be interpreted apropriately.
    open func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        return undefined()
    }

    /// Implement and return `true` if this supervisor can handle the failure or not.
    /// If `false` is returned and other supervisors are present, they will be tied in order, until a supervisor which
    /// can handle the failure is found, or if no such supervisor exists the failure will cause the actor to crash (as expected).
    open func canHandle(failure: Supervision.Failure) -> Bool {
        return undefined()
    }

    /// Invoked when wrapping (with this `Supervisor`) a `Behavior` that already is supervised.
    ///
    /// The method is always invoked _on_ the existing supervisor with the "new" supervisor.
    /// If this method returns `true` the new supervisor will be dropped and no wrapping will be performed.
    func isSame(as other: Supervisor<Message>) -> Bool {
        return undefined()
    }
}

/// Supervisor equivalent to not having supervision enabled, since stopping is the default behavior of failing actors.
/// At the same time, it may be useful to sometimes explicitly specify that for some type of error we want to stop
/// (e.g. when used with composite supervisors, which restart for all failures, yet should not do so for some specific type of error).
final class StoppingSupervisor<Message>: Supervisor<Message> {
    internal let failureType: Error.Type

    internal init(failureType: Error.Type) {
        self.failureType = failureType
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        guard failure.shouldBeHandled(bySupervisorHandling: failureType) else {
            // TODO matters perhaps only for metrics where we'd want to "please count this specific type of error" so leaving this logic as-is
            return .stop
        }

        return .stop
    }

    override func isSame(as other: Supervisor<Message>) -> Bool {
        if let other = other as? StoppingSupervisor<Message> {
            return self.failureType == other.failureType
        } else {
            return false
        }
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        return failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }
}

// There are a few ways we could go about implementing this, we currently do a simple scan for "first one that handles",
// which should be quite good enough esp. since we expect the supervisors to be usually not more than just a few.
//
// The scan also makes implementing the "catch" all types `Supervision.AllFailures` etc simpler rather than having to search
// the underlying map for the catch all handlers as well as the specific error.
final class CompositeSupervisor<Message>: Supervisor<Message> {
    private let supervisors: [Supervisor<Message>]

    init(supervisors: [Supervisor<Message>]) {
        assert(supervisors.count > 1, "There is no need to use a composite supervisor if only one supervisor is passed in. Consider this a Swift Distributed Actors bug.")
        self.supervisors = supervisors
        super.init()
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> SupervisionDirective<Message> {
        for supervisor in supervisors {
            if supervisor.canHandle(failure: failure) {
                return try supervisor.handleFailure(context, target: target, failure: failure, processingType: processingType)
            }
        }
        return .stop
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        return self.supervisors.contains { $0.canHandle(failure: failure) }
    }
}

/// Instructs the mailbox to take specific action, reflecting wha the supervisor intends to do with the actor.
///
/// - SeeAlso: `Supervisor.handleFailure`
enum SupervisionDirective<Message> {
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

enum SupervisionDecision {
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

        if self.periodHasTimeLeft && self.isWithinMaxRestarts {
            guard self.backoffStrategy != nil else {
                return .restartImmediately
            }

            // so the backoff strategy _is_ set, and a `nil` from it would mean "stop restarting"
            if let backoffAmount = self.backoffStrategy?.next() {
                return .restartBackoff(delay: backoffAmount)
            } else {
                // TODO: or plain stop? now they are the same though...
                // we stop/escalate since the strategy decided we've been trying again enough and it is time to stop
                return .escalate
            }

        } else {
            // e.g. total time within which we are allowed to back off has been exceeded etc
            return .escalate
        }
    }

    private var periodHasTimeLeft:  Bool {
        return self.restartsPeriodDeadline.hasTimeLeft(until: .now())
    }

    private var isWithinMaxRestarts: Bool {
        return self.restartsWithinCurrentPeriod <= self.maxRestarts
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

final class RestartingSupervisor<Message>: Supervisor<Message> {
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
            traceLog_Supervision("ESCALATE from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")

            return .stop
        }

        switch decision {
        case .stop:
            traceLog_Supervision("STOP from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")

            return .stop

        case .escalate:
            traceLog_Supervision("ESCALATE from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")

            return .escalate(failure)

        case .restartImmediately:
            // TODO make proper .ordinalString function
            traceLog_Supervision("RESTART from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")
            // TODO has to modify restart counters here and supervise with modified supervisor

            return .restartImmediately(self.initialBehavior)

        case .restartBackoff(let delay):
            traceLog_Supervision("RESTART BACKOFF(\(delay.prettyDescription)) from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")

            return .restartDelayed(delay, self.initialBehavior)
        }
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        return failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }

    // TODO complete impl
    override public func isSame(as other: Supervisor<Message>) -> Bool {
        return other is RestartingSupervisor<Message>
    }
}

/// Behavior used to suspend after a `restartPrepare` has been issued by an `restartDelayed`.
internal enum SupervisionRestartDelayedBehavior<Message> {
    internal struct WakeUp {}

    static func after(delay: TimeAmount, with replacement: Behavior<Message>) -> Behavior<Message> {
        return .setup { context in
            context.timers._startResumeTimer(key: "_restartBackoff", delay: delay, resumeWith: WakeUp())

            return .suspend { (result: Result<WakeUp, ExecutionError>) in
                traceLog_Supervision("RESTART BACKOFF TRIGGER")
                switch result {
                case .failure(let error):
                    context.log.error("Failed result during backoff restart. Error was: \(error). Forcing actor to crash.")
                    return .failed(error: error)
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
        return "RestartingSupervisor(initialBehavior: \(initialBehavior), strategy: \(self.restartDecider), canHandle: \(self.failureType))"
    }
}

fileprivate extension Supervision.Failure {
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
