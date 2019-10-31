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

import struct Dispatch.DispatchTime
import struct Foundation.Date
import struct NIO.TimeAmount

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TimeAmount

// TODO: We have discussed and wanted to "do your own" rather than import the NIO ones, but not entirely sold on the usefulness of replicating them -- ktoso

/// Represents a time _interval_.
///
/// - note: `TimeAmount` should not be used to represent a point in time.
public struct TimeAmount {
    public typealias Value = Int64

    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Value

    fileprivate init(_ nanoseconds: Value) { // FIXME: Needed the copy since this constructor
        self.nanoseconds = nanoseconds
    }

    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func nanoseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount)
    }

    public static func nanoseconds(_ amount: Int) -> TimeAmount {
        return self.nanoseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of microseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func microseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000)
    }

    public static func microseconds(_ amount: Int) -> TimeAmount {
        return self.microseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func milliseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000)
    }

    public static func milliseconds(_ amount: Int) -> TimeAmount {
        return self.milliseconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - parameters:
    ///     - amount: the amount of seconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func seconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000)
    }

    public static func seconds(_ amount: Int) -> TimeAmount {
        return self.seconds(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func minutes(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60)
    }

    public static func minutes(_ amount: Int) -> TimeAmount {
        return self.minutes(Value(amount))
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func hours(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60 * 60)
    }

    public static func hours(_ amount: Int) -> TimeAmount {
        return self.hours(Value(amount))
    }
}

extension TimeAmount: Comparable {
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds < rhs.nanoseconds
    }

    public static func == (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds == rhs.nanoseconds
    }
}

/// "Pretty" time amount rendering, useful for human readable durations in tests
extension TimeAmount: CustomStringConvertible {
    public var description: String {
        return "TimeAmount(\(self.prettyDescription), nanoseconds: \(self.nanoseconds))"
    }

    public var prettyDescription: String {
        return self.prettyDescription()
    }

    public func prettyDescription(precision: Int = 2) -> String {
        assert(precision > 0, "precision MUST BE > 0")
        if self.isEffectivelyInfinite {
            return "∞ (infinite)"
        }

        var res = ""
        var remainingNanos = self.nanoseconds

        if remainingNanos < 0 {
            res += "-"
            remainingNanos = remainingNanos * -1
        }

        var i = 0
        while i < precision {
            let unit = chooseUnit(remainingNanos)

            let rounded = Int(remainingNanos / unit.rawValue)
            if rounded > 0 {
                res += i > 0 ? " " : ""
                res += "\(rounded)\(unit.abbreviated)"

                remainingNanos = remainingNanos - unit.timeAmount(rounded).nanoseconds
                i += 1
            } else {
                break
            }
        }

        return res
    }

    private func chooseUnit(_ ns: Value) -> TimeUnit {
        // @formatter:off
        if ns / TimeUnit.days.rawValue > 0 {
            return TimeUnit.days
        } else if ns / TimeUnit.hours.rawValue > 0 {
            return TimeUnit.hours
        } else if ns / TimeUnit.minutes.rawValue > 0 {
            return TimeUnit.minutes
        } else if ns / TimeUnit.seconds.rawValue > 0 {
            return TimeUnit.seconds
        } else if ns / TimeUnit.milliseconds.rawValue > 0 {
            return TimeUnit.milliseconds
        } else if ns / TimeUnit.microseconds.rawValue > 0 {
            return TimeUnit.microseconds
        } else {
            return TimeUnit.nanoseconds
        }
        // @formatter:on
    }

    /// Represents number of nanoseconds within given time unit
    enum TimeUnit: Value {
        // @formatter:off
        case days = 86_400_000_000_000
        case hours = 3_600_000_000_000
        case minutes = 60_000_000_000
        case seconds = 1_000_000_000
        case milliseconds = 1_000_000
        case microseconds = 1000
        case nanoseconds = 1
        // @formatter:on

        var abbreviated: String {
            switch self {
            case .nanoseconds: return "ns"
            case .microseconds: return "μs"
            case .milliseconds: return "ms"
            case .seconds: return "s"
            case .minutes: return "m"
            case .hours: return "h"
            case .days: return "d"
            }
        }

        func timeAmount(_ amount: Int) -> TimeAmount {
            switch self {
            case .nanoseconds: return .nanoseconds(Value(amount))
            case .microseconds: return .microseconds(Value(amount))
            case .milliseconds: return .milliseconds(Value(amount))
            case .seconds: return .seconds(Value(amount))
            case .minutes: return .minutes(Value(amount))
            case .hours: return .hours(Value(amount))
            case .days: return .hours(Value(amount) * 24)
            }
        }
    }

    public var toNIO: NIO.TimeAmount {
        return NIO.TimeAmount.nanoseconds(Int64(self.nanoseconds))
    }
}

public extension TimeAmount {
    /// The microseconds representation of the `TimeAmount`.
    var microseconds: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.microseconds.rawValue
    }

    /// The milliseconds representation of the `TimeAmount`.
    var milliseconds: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.milliseconds.rawValue
    }

    /// The seconds representation of the `TimeAmount`.
    var seconds: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.seconds.rawValue
    }

    /// The minutes representation of the `TimeAmount`.
    var minutes: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.minutes.rawValue
    }

    /// The hours representation of the `TimeAmount`.
    var hours: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.hours.rawValue
    }

    /// The days representation of the `TimeAmount`.
    var days: Int64 {
        return self.nanoseconds / TimeAmount.TimeUnit.days.rawValue
    }

    /// Returns true if the time amount is "effectively infinite" (equal to `TimeAmount.effectivelyInfinite`)
    var isEffectivelyInfinite: Bool {
        return self == TimeAmount.effectivelyInfinite
    }
}

public extension TimeAmount {
    /// Largest time amount expressible using this type.
    /// Roughly equivalent to 292 years, which for the intents and purposes of this type can serve as "infinite".
    static var effectivelyInfinite: TimeAmount {
        return TimeAmount(Value.max)
    }

    /// Smallest non-negative time amount.
    static var zero: TimeAmount {
        return TimeAmount(0)
    }
}

public extension TimeAmount {
    static func + (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        return .nanoseconds(lhs.nanoseconds + rhs.nanoseconds)
    }

    static func - (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        return .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }

    static func * (lhs: TimeAmount, rhs: Int) -> TimeAmount {
        return TimeAmount(lhs.nanoseconds * Value(rhs))
    }

    static func * (lhs: TimeAmount, rhs: Double) -> TimeAmount {
        return TimeAmount(Int64(Double(lhs.nanoseconds) * rhs))
    }

    static func / (lhs: TimeAmount, rhs: Int) -> TimeAmount {
        return TimeAmount(lhs.nanoseconds / Value(rhs))
    }

    static func / (lhs: TimeAmount, rhs: Double) -> TimeAmount {
        return TimeAmount(Int64(Double(lhs.nanoseconds) / rhs))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Deadline

// TODO: Deadline based on https://github.com/apple/swift-nio/pull/770/files (removed our own), we need to decide what to do with these types. -- ktoso

/// Represents a point in time.
///
/// Stores the time in nanoseconds as returned by `DispatchTime.now().uptimeNanoseconds`
///
/// `Deadline` allow chaining multiple tasks with the same deadline without needing to
/// compute new timeouts for each step
///
/// ```
/// func doSomething(deadline: Deadline) -> EventLoopFuture<Void> {
///     return step1(deadline: deadline).then {
///         step2(deadline: deadline)
///     }
/// }
/// doSomething(deadline: .now() + .seconds(5))
/// ```
///
/// - note: `Deadline` should not be used to represent a time interval
public struct Deadline: Equatable, Hashable {
    public typealias Value = Int64

    /// The nanoseconds since boot representation of the `Deadline`.
    public let uptimeNanoseconds: Value

    public init(_ uptimeNanoseconds: Value) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static let distantPast = Deadline(0)
    public static let distantFuture = Deadline(Value.max)

    public static func now() -> Deadline {
        return uptimeNanoseconds(Deadline.Value(DispatchTime.now().uptimeNanoseconds))
    }

    public static func uptimeNanoseconds(_ nanoseconds: Value) -> Deadline {
        return Deadline(nanoseconds)
    }
}

extension Deadline: Comparable {
    public static func < (lhs: Deadline, rhs: Deadline) -> Bool {
        return lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func > (lhs: Deadline, rhs: Deadline) -> Bool {
        return lhs.uptimeNanoseconds > rhs.uptimeNanoseconds
    }
}

extension Deadline: CustomStringConvertible {
    public var description: String {
        return self.uptimeNanoseconds.description
    }
}

extension Deadline {
    public static func - (lhs: Deadline, rhs: Deadline) -> TimeAmount {
        return .nanoseconds(TimeAmount.Value(lhs.uptimeNanoseconds) - TimeAmount.Value(rhs.uptimeNanoseconds))
    }

    public static func + (lhs: Deadline, rhs: TimeAmount) -> Deadline {
        if rhs.nanoseconds < 0 {
            return Deadline(lhs.uptimeNanoseconds - Deadline.Value(rhs.nanoseconds.magnitude))
        } else {
            return Deadline(lhs.uptimeNanoseconds + Deadline.Value(rhs.nanoseconds.magnitude))
        }
    }

    public static func - (lhs: Deadline, rhs: TimeAmount) -> Deadline {
        if rhs.nanoseconds < 0 {
            return Deadline(lhs.uptimeNanoseconds + Deadline.Value(rhs.nanoseconds.magnitude))
        } else {
            return Deadline(lhs.uptimeNanoseconds - Deadline.Value(rhs.nanoseconds.magnitude))
        }
    }
}

public extension Deadline {
    static func fromNow(_ amount: TimeAmount) -> Deadline {
        return .now() + amount
    }

    /// - Returns: true if the deadline is still pending with respect to the passed in `now` time instant
    func hasTimeLeft() -> Bool {
        return self.hasTimeLeft(until: .now())
    }

    func hasTimeLeft(until: Deadline) -> Bool {
        return !self.isBefore(until)
    }

    /// - Returns: true if the deadline is overdue with respect to the passed in `now` time instant
    func isOverdue() -> Bool {
        return self.isBefore(.now())
    }

    func isBefore(_ until: Deadline) -> Bool {
        return self.uptimeNanoseconds < until.uptimeNanoseconds
    }

    var timeLeft: TimeAmount {
        return .nanoseconds(self.uptimeNanoseconds - Deadline.now().uptimeNanoseconds)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Clock

/// Represents a timestamp with total order defined and therefore can be compared to establish causal order.
public protocol AbstractClock: Comparable {
    init()
}

/// A `Clock` implementation using `Date`.
public struct SystemClock: AbstractClock {
    internal let timestamp: Date

    public init() {
        self.init(timestamp: Date())
    }

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }

    public static func < (lhs: SystemClock, rhs: SystemClock) -> Bool {
        return lhs.timestamp < rhs.timestamp
    }

    public static func == (lhs: SystemClock, rhs: SystemClock) -> Bool {
        return lhs.timestamp == rhs.timestamp
    }
}
