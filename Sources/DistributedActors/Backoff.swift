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

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Backoff Strategy protocol

/// A `BackoffStrategy` abstracts over logic which computes appropriate time amounts to back off at, for a specific call.
///
/// Create instances using `Backoff`, e.g. `Backoff.exponential(...)`, or implement custom strategies by conforming to this protocol.
///
/// See also: `ConstantBackoffStrategy`, `ExponentialBackoffStrategy`
public protocol BackoffStrategy {
    /// Returns next backoff interval to use OR `nil` if no further retries should be performed.
    mutating func next() -> TimeAmount?

    /// Reset the strategy to its initial backoff amount.
    mutating func reset()
}

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Backoff Strategy implementations

/// Factory for `BackoffStrategy` instances.
///
/// - SeeAlso: `BackoffStrategy` for interface semantics.
/// - SeeAlso: `ConstantBackoffStrategy` for a simple constant backoff strategy.
/// - SeeAlso: `ExponentialBackoffStrategy` for a most commonly used exponentially-increasing strategy.
///
/// - SeeAlso: Also used to configure `SupervisionStrategy`.
public enum Backoff {
    // TODO: implement noLongerThan: .seconds(30), where total time is taken from actor system clock

    /// Backoff each time using the same, constant, time amount.
    ///
    /// See `ConstantBackoffStrategy` for details
    static func constant(_ backoff: TimeAmount) -> ConstantBackoffStrategy {
        return .init(timeAmount: backoff)
    }

    /// Creates a strategy implementing the exponential backoff pattern.
    ///
    /// See `ExponentialBackoffStrategy` for details.
    ///
    /// - Parameters:
    ///   - initialInterval: interval to use as base of all further backoffs,
    ///         usually also the value used for the first backoff.
    ///         MUST be `> 0`.
    ///   - multiplier: multiplier to be applied on each subsequent backoff to the previous backoff interval.
    ///         For example, a value of 1.5 means that each backoff will increase 50% over the previous value.
    ///         MUST be `>= 0`.
    ///   - maxInterval: interval limit, beyond which intervals should be truncated to this value.
    ///         MUST be `>= initialInterval`.
    ///   - randomFactor: A random factor of `0.5` results in backoffs between 50% below and 50% above the base interval.
    ///         MUST be between: `<0; 1>` (inclusive)
    static func exponential(
        initialInterval: TimeAmount = ExponentialBackoffStrategy.Defaults.initialInterval,
        multiplier: Double = ExponentialBackoffStrategy.Defaults.multiplier,
        maxInterval: TimeAmount = ExponentialBackoffStrategy.Defaults.capInterval,
        randomFactor: Double = ExponentialBackoffStrategy.Defaults.randomFactor
    ) -> ExponentialBackoffStrategy {
        return .init(initialInterval: initialInterval, multiplier: multiplier, capInterval: maxInterval, randomFactor: randomFactor)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Constant backoff strategy

/// Simple strategy, always yielding the same backoff interval.
///
/// - SeeAlso: `ExponentialBackoffStrategy` for a most commonly used exponentially-increasing strategy
///
/// - SeeAlso: Also used to configure `SupervisionStrategy`.
public struct ConstantBackoffStrategy: BackoffStrategy {
    /// The constant time amount to back-off by each time.
    internal let timeAmount: TimeAmount

    public init(timeAmount: TimeAmount) {
        self.timeAmount = timeAmount
    }

    public func next() -> TimeAmount? {
        return self.timeAmount
    }

    public func reset() {
        // no-op
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Exponential backoff strategy

/// Backoff strategy exponentially yielding greater time amounts each time when triggered.
///
/// Subsequent `next()` invocations cause the base interval amount to grow exponentially (as powers of two).
///
/// Additional random "noise" is applied to the backoff value, in order to avoid multiple actors or nodes re-trying
/// at the same exact rate. The effective backoff time amount is calculated as current base interval multiplied by a random
/// value within the range: `(1 - randomFactor)...(1 + randomFactor)`. Meaning that the actual backoff value will "oscillate"
/// around the expected backoff base, but ever so slightly different each time it is calculated, allowing multiple actors or nodes
/// to attempt retries without causing as much of a tendering heard effect upon the (possibly shared) target resource.
///
/// Example backoff values for `.exponential(initialInterval: .milliseconds(100), randomFactor: 0.25)`:
///
/// | Attempt | multiplier | randomFact |  (base) | (randomized range) |
/// | ------- | ---------- | ---------- | ------- | ------------------ |
/// |       1 |        1.5 |       0.25 |   100ms |   75ms ...  125ms  |
/// |       2 |        1.5 |       0.25 |   150ms | ~127ms ... ~188ms  |
/// |       3 |        1.5 |       0.25 |   225ms | ~191ms ... ~281ms  |
/// |       4 |        1.5 |       0.25 |  ~338ms | ~287ms ... ~422ms  |
/// |       5 |        1.5 |       0.25 |  ~506ms | ~680ms ... ~633ms  |
/// |     ... |        ... |        ... |     ... |        ...         |
///
/// Additionally the `maxInterval` can be used to _cap_ the backoff time amount.
/// Note that the backoff will continue yielding the `maxInterval` infinitely times if it has been exceeded,
/// and other means of preventing infinite retries should be applied.
///
/// By changing the `multiplier` it is possible to control the rate at which backoff intervals grow over subsequent attempts.
/// The default value of `1.5` results in a 50% growth of for each `next()` call. Applications wanting to double the backoff
/// interval upon each attempt may set the `multiplier` would be set to `2.0`. Higher multiplier values are also accepted,
/// but not frequently used.
///
/// - SeeAlso: `ConstantBackoffStrategy` for a simple constant backoff strategy.
///
/// - SeeAlso: Also used to configure `SupervisionStrategy`.
public struct ExponentialBackoffStrategy: BackoffStrategy {
    // TODO: clock + limit "max total wait time" etc

    /// Default values for the backoff parameters.
    public struct Defaults {
        public static let initialInterval: TimeAmount = .milliseconds(200)
        public static let multiplier: Double = 1.5
        public static let capInterval: TimeAmount = .seconds(30)
        public static let randomFactor: Double = 0.25

        // TODO: We could also implement taking a Clock, and using it see if there's a total limit exceeded
        // public static let maxElapsedTime: TimeAmount = .minutes(30)
    }

    let initialInterval: TimeAmount
    let multiplier: Double
    let capInterval: TimeAmount
    let randomFactor: Double

    // interval that will be used in the `next()` call, does NOT include the random noise component
    private var currentBaseInterval: TimeAmount

    internal init(initialInterval: TimeAmount, multiplier: Double, capInterval: TimeAmount, randomFactor: Double) {
        precondition(initialInterval.nanoseconds > 0, "initialInterval MUST be > 0ns, was: [\(initialInterval.prettyDescription)]")
        precondition(multiplier >= 1.0, "multiplier MUST be >= 1.0, was: [\(multiplier)]")
        precondition(initialInterval <= capInterval, "capInterval MUST be >= initialInterval, was: [\(capInterval)]")
        precondition(randomFactor >= 0.0 && randomFactor <= 1.0, "randomFactor MUST be within between 0 and 1, was: [\(randomFactor)]")

        self.initialInterval = initialInterval
        self.currentBaseInterval = initialInterval
        self.multiplier = multiplier
        self.capInterval = capInterval
        self.randomFactor = randomFactor
    }

    public mutating func next() -> TimeAmount? {
        let baseInterval = self.currentBaseInterval
        let randomizeMultiplier = Double.random(in: (1 - self.randomFactor) ... (1 + self.randomFactor))

        if baseInterval > self.capInterval {
            let randomizedCappedInterval = self.capInterval * randomizeMultiplier
            return randomizedCappedInterval
        } else {
            let randomizedInterval = baseInterval * randomizeMultiplier
            // TODO: potentially logic to check clock if we exceeded total backoff timeout here (and then return nil)
            self.prepareNextInterval()
            return randomizedInterval
        }
    }

    private mutating func prepareNextInterval() {
        // overflow protection
        if self.currentBaseInterval >= (self.capInterval / self.multiplier) {
            self.currentBaseInterval = self.capInterval
        } else {
            self.currentBaseInterval = self.currentBaseInterval * self.multiplier
        }
    }

    public mutating func reset() {
        self.currentBaseInterval = self.initialInterval
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

// MARK: Errors

enum BackoffError {
    case exceededNumberOfAttempts(limit: Int, period: TimeAmount)
}
