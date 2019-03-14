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

// MARK: Supervision props and strategies

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
    /// Creates a new `Props` appending an supervisor for the selected failure type.
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: error type selector, determining for what type of error the given supervisor should perform its logic.
    static func addSupervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = Props()
        props.supervision = props.supervision.adding(strategy: strategy, forErrorType: errorType)
        return props
    }
    /// Creates a new `Props` appending an supervisor for the selected failure type.
    /// Note that order in which overlapping selectors/types are added to the chain matters.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    static func addSupervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        return addSupervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }

    /// Adds another supervisor to the chain of existing supervisors in this `Props`, useful for setting a few options in-line when spawning actors.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forErrorType: error type selector, determining for what type of error the given supervisor should perform its logic.
    func addSupervision(strategy: SupervisionStrategy, forErrorType errorType: Error.Type) -> Props {
        var props = self
        props.supervision.add(strategy: strategy, forErrorType: errorType)
        return props
    }
    /// Adds another supervisor to the chain of existing supervisors in this `Props`, useful for setting a few options in-line when spawning actors.
    ///
    /// - Parameters:
    ///   - strategy: supervision strategy to apply for the given class of failures
    ///   - forAll: failure type selector, working as a "catch all" for the specific types of failures.
    func addSupervision(strategy: SupervisionStrategy, forAll selector: Supervise.All = .failures) -> Props {
        return self.addSupervision(strategy: strategy, forErrorType: Supervise.internalErrorTypeFor(selector: selector))
    }
}

/// Supervision strategies are a way to select and configure pre-defined supervisors.
public enum SupervisionStrategy {
    /// Default supervision strategy applied to all actors, unless a different one is selected in their `Props`.
    ///
    /// Semantically equivalent to not applying any supervision strategy at all, since not applying a strategy
    /// also means that upon encountering a failure the given actor is terminated and all of its watchers are terminated.
    ///
    /// - SeeAlso: `DeathWatch` for discussion about how to be notified about an actor stopping / failing.
    case stop

    /// Supervision strategy allowing the supervised actor to be restarted `atMost` times `within` a time period.
    ///
    /// The following visualization may be useful in understanding failure periods and their meaning to the "intensity"
    /// of how many restarts are allowed within a failure period:
    /// ```
    /// Assuming supervision with: .restart(atMost: 2, within: .seconds(10))
    ///
    ///      fail-per-1  fail-per-2                    failure-period-3
    /// TFP: 0123456789  0123456789                       0123456789
    ///     [x        x][x         ][... no failures ...][x   x  x!!]
    ///      ^        ^  ^                                ^      ^
    ///      |        |  |                                |      \ and whenever we hit a 3rd failure within it, we escalate (do do restart, and the actor is stopped)
    ///      |        |  |                                \ any new failure after a while causes a new failure period
    ///      |        |  \ another, 3rd in total, failure happens; however it is the beginning of a new failure period; we allow the restart
    ///      |        \ another failure happens in before the end of the period, atMost: 2, so we perform the restart
    ///      \- a failure begins a failure period of 10 seconds
    /// ```
    ///
    /// - Warning:
    /// While it is possible to omit the `within` parameter, it has a specific effect which may not often be useful:
    /// a `restart` supervision directive without a `within` parameter set effectively means that a given actor is allowed to restart
    /// `atMost` times _in total_ (in its entire lifetime). This rarely is a behavior one would desire, however it may sometimes come in handy.
    ///
    /// **Associated Values**
    ///   - `atMost` number of attempts allowed restarts within a single failure period (defined by the `within` parameter. MUST be > 0.
    ///   - `within` amount of time within which the `atMost` failures are allowed to happen. This defines the so called "failure period",
    ///     which runs from the first failure encountered for `within` time, and if more than `atMost` failures happen in this time amount then
    ///     no restart is performed and the failure is escalated (and the actor terminates in the process).
    case restart(atMost: Int, within: TimeAmount?) // TODO would like to remove the `?` and model more properly
    // TODO: backoff supervision https://github.com/apple/swift-distributed-actors/issues/133
}

internal struct ErrorTypeBoundSupervisionStrategy {
    let failureType: Error.Type
    let strategy: SupervisionStrategy
}

public struct Supervision {

    /// Internal conversion from supervision props to apropriate (potentially composite) `Supervisor<Message>`.
    internal static func supervisorFor<Message>(_ system: ActorSystem, initialBehavior: Behavior<Message>, props: SupervisionProps) -> Supervisor<Message> {
        func supervisorFor0(failureType: Error.Type, strategy: SupervisionStrategy) -> Supervisor<Message> {
            switch strategy {
            case let .restart(atMost, within):
                let strategy = RestartDecisionLogic(maxRestarts: atMost, within: within)
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
/// - message: failure happened during messsage processing
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

    @inlinable
    final internal func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, message: Message) throws -> Behavior<Message> {
        traceLog_Supervision("CALL WITH SUPERVISION: \(target) @@@@ [\(message)]:\(type(of: message))")
        return try self.interpretSupervised0(target: target, context: context, processingType: .message) {
            return try target.interpretMessage(context: context, message: message) // no-op implementation by default
        }
    }

    @inlinable
    final internal func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        traceLog_Supervision("INTERCEPT SIGNAL APPLY: \(target) @@@@ \(signal)")
        return try self.interpretSupervised0(target: target, context: context, processingType: .signal) {
            return try target.interpretSignal(context: context, signal: signal)
        }
    }

    @inlinable
    final internal func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, closure: () throws -> Void) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE")
        return try self.interpretSupervised0(target: target, context: context, processingType: .closure) {
            try closure()
            return .same
        }
    }

    @inlinable
    final internal func interpretSupervised(target: Behavior<Message>, context: ActorContext<Message>, continuation: () throws -> Behavior<Message>) throws -> Behavior<Message> {
        traceLog_Supervision("CALLING CLOSURE")
        return try self.interpretSupervised0(target: target, context: context, processingType: .continuation) {
            return try continuation()
        }
    }

    @usableFromInline
    func interpretSupervised0(target: Behavior<Message>, context: ActorContext<Message>, processingType: ProcessingType, block: () throws -> Behavior<Message>) throws -> Behavior<Message> {
        do {
            return try block()
        } catch {
            let err = error
            context.log.warning("Supervision: Actor has THROWN [\(error)]:\(type(of: error)) while interpreting \(processingType), handling with \(self)", error: error)
            do {
                return try self.handleFailure(context, target: target, failure: .error(error), processingType: processingType).validatedAsInitial()
            } catch {
                throw Supervision.DecisionError.illegalDecision("Illegal supervision decision detected.", handledError: err, error: error)
            }
        }
    }

    // MARK: Internal Supervisor API

    /// Handle a fault that happened during processing.
    // TODO wording and impl on double-faults
    open func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> Behavior<Message> {
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
/// At the same time, it may be useful to sometimes explicitly specifiy that for some type of error we want to stop
/// (e.g. when used with composite supervisors, which restart for all failures, yet should not do so for some specific type of error).
final class StoppingSupervisor<Message>: Supervisor<Message> {
    internal let failureType: Error.Type

    internal init(failureType: Error.Type) {
        self.failureType = failureType
    }

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> Behavior<Message> {
        guard failure.shouldBeHandled(bySupervisorHandling: failureType) else {
            // TODO matters perhaps only for metrics where we'd want to "please count this specific type of error" so leaving this logic as-is
            return .stopped // TODO .escalate could be nicer
        }

        return .stopped
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

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> Behavior<Message> {
        for supervisor in supervisors {
            if supervisor.canHandle(failure: failure) {
                return try supervisor.handleFailure(context, target: target, failure: failure, processingType: processingType)
            }
        }
        return .stopped // TODO: escalate could be nicer
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        return self.supervisors.contains { $0.canHandle(failure: failure) }
    }
}

/// Encapsulates logic around when a restart is allowed, i.e. tracks the deadlines of failure periods.
internal struct RestartDecisionLogic {
    let maxRestarts: Int
    let within: TimeAmount?

    typealias ShouldRestart = Bool

    // counts how many times we failed during the "current" `within` period
    private var restartsWithinCurrentPeriod: Int = 0
    private var restartsPeriodDeadline: Deadline = Deadline.distantPast

    init(maxRestarts: Int, within: TimeAmount?) {
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

    }

    /// Increment the failure counter (and possibly reset the failure period deadline).
    ///
    /// MUST be called whenever a failure reaches a supervisor.
    mutating func recordFailure() -> ShouldRestart {
        if self.restartsPeriodDeadline.isOverdue() {
            // thus the next period starts, and we will start counting the failures within that time window anew

            // ! safe, because we are guaranteed to never exceed the .distantFuture deadline that is set when within is nil
            let failurePeriodTimeAmount = self.within!
            self.restartsPeriodDeadline = .fromNow(failurePeriodTimeAmount)
            self.restartsWithinCurrentPeriod = 0
        }
        self.restartsWithinCurrentPeriod += 1

        return self.periodHasTimeLeft && self.isWithinMaxRestarts
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

    override func handleFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure, processingType: ProcessingType) throws -> Behavior<Message> {
        let shouldRestart: RestartDecisionLogic.ShouldRestart = self.restartDecider.recordFailure()
        guard failure.shouldBeHandled(bySupervisorHandling: self.failureType) && shouldRestart else {
            traceLog_Supervision("Supervision: STOP from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")
            return .stopped // TODO .escalate ???
        }

        // TODO make proper .ordinalString function
        traceLog_Supervision("Supervision: RESTART from \(processingType) (\(self.restartDecider.remainingRestartsDescription)), failure was: \(failure)! >>>> \(initialBehavior)")
        // TODO has to modify restart counters here and supervise with modified supervisor

        context.children.stopAll()

        _ = try target.interpretSignal(context: context, signal: Signals.PreRestart())

        return try initialBehavior.start(context: context)
    }

    override func canHandle(failure: Supervision.Failure) -> Bool {
        return failure.shouldBeHandled(bySupervisorHandling: self.failureType)
    }

    // TODO complete impl
    override public func isSame(as other: Supervisor<Message>) -> Bool {
        return other is RestartingSupervisor<Message>
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
