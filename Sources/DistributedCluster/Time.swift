//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import enum Dispatch.DispatchTimeInterval
import struct NIO.TimeAmount

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Duration

extension Duration {
    typealias Value = Int64

    var nanoseconds: Value {
        let (seconds, attoseconds) = self.components
        let sNanos = seconds * Value(1_000_000_000)
        let asNanos = attoseconds / Value(1_000_000_000)
        let (totalNanos, overflow) = sNanos.addingReportingOverflow(asNanos)
        return overflow ? .max : totalNanos
    }

    /// The microseconds representation of the `TimeAmount`.
    var microseconds: Value {
        self.nanoseconds / TimeUnit.microseconds.rawValue
    }

    /// The milliseconds representation of the `TimeAmount`.
    var milliseconds: Value {
        self.nanoseconds / TimeUnit.milliseconds.rawValue
    }

    /// The seconds representation of the `TimeAmount`.
    var seconds: Value {
        self.nanoseconds / TimeUnit.seconds.rawValue
    }

    var isEffectivelyInfinite: Bool {
        self.nanoseconds == .max
    }
}

extension Duration {
    /// Creates a new `Duration` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `Duration` represents.
    /// - returns: the `Duration` for the given amount.
    static func minutes(_ amount: Value) -> Duration {
        .nanoseconds(amount * 1000 * 1000 * 1000 * 60)
    }

    static func minutes(_ amount: Int) -> Duration {
        self.minutes(Value(amount))
    }

    /// Creates a new `Duration` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `Duration` represents.
    /// - returns: the `Duration` for the given amount.
    static func hours(_ amount: Value) -> Duration {
        .nanoseconds(amount * 1000 * 1000 * 1000 * 60 * 60)
    }

    static func hours(_ amount: Int) -> Duration {
        self.hours(Value(amount))
    }

    /// Largest time amount expressible using this type.
    /// Roughly equivalent to 292 years, which for the intents and purposes of this type can serve as "infinite".
    static var effectivelyInfinite: Duration = .nanoseconds(Value.max)
}

extension Duration: CustomPrettyStringConvertible {
    public var prettyDescription: String {
        self.prettyDescription()
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

                remainingNanos = remainingNanos - unit.duration(rounded).nanoseconds
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

        func duration(_ duration: Int) -> Duration {
            switch self {
            case .nanoseconds: return .nanoseconds(Value(duration))
            case .microseconds: return .microseconds(Value(duration))
            case .milliseconds: return .milliseconds(Value(duration))
            case .seconds: return .seconds(Value(duration))
            case .minutes: return .minutes(Value(duration))
            case .hours: return .hours(Value(duration))
            case .days: return .hours(Value(duration) * 24)
            }
        }
    }
}

extension Duration {
    var toNIO: NIO.TimeAmount {
        .nanoseconds(self.nanoseconds)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instant

extension ContinuousClock.Instant {
    static var distantPast: ContinuousClock.Instant {
        .now - Duration.effectivelyInfinite
    }

    static var distantFuture: ContinuousClock.Instant {
        .now + Duration.effectivelyInfinite
    }

    static func fromNow(_ amount: Duration) -> ContinuousClock.Instant {
        .now + amount
    }

    /// - Returns: true if the deadline is still pending with respect to the passed in `now` time instant
    func hasTimeLeft() -> Bool {
        self.hasTimeLeft(until: .now)
    }

    func hasTimeLeft(until: ContinuousClock.Instant) -> Bool {
        !self.isBefore(until)
    }

    /// - Returns: true if the deadline is overdue with respect to the passed in `now` time instant
    func isOverdue() -> Bool {
        self.isBefore(.now)
    }

    func isBefore(_ until: ContinuousClock.Instant) -> Bool {
        self < until
    }

    var timeLeft: Duration {
        self - .now
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dispatch time

extension DispatchTimeInterval: CustomPrettyStringConvertible {
    /// Total amount of nanoseconds represented by this interval.
    ///
    /// We need this to compare amounts, yet we don't want to make to Comparable publicly.
    var nanoseconds: Int64 {
        switch self {
        case .nanoseconds(let ns): return Int64(ns)
        case .microseconds(let us): return Int64(us) * 1000
        case .milliseconds(let ms): return Int64(ms) * 1_000_000
        case .seconds(let s): return Int64(s) * 1_000_000_000
        default: return .max
        }
    }

    var isEffectivelyInfinite: Bool {
        self.nanoseconds == .max
    }
}
