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

import NIO
import Swift Distributed ActorsActor
import Foundation

/// A `Deadline` represents a point in time after which some action is expected to happen.
/// This is useful for triggering timeouts and similar.
public struct Deadline: Equatable {
    let instant: Date

    public init(instant: Date) {
        self.instant = instant
    }

    public static func fromNow(amount: TimeAmount) -> Deadline {
        return fromNow(now: Date(), amount: amount)
    }

    public static func fromNow(now: Date, amount: TimeAmount) -> Deadline {
        let v = TimeInterval(Int(Double(exactly: amount.nanoseconds)! / 1e+9))
        return Deadline(instant: now.addingTimeInterval(v)) // FIXME how can I go below seconds?
    }

    /// - Returns: true if the deadline is still pending with respect to the passed in `now` time instant
    func hasTimeLeft(now: Date) -> Bool {
        return !isOverdue(now: now)
    }

    /// - Returns: true if the deadline is overdue with respect to the passed in `now` time instant
    func isOverdue(now: Date) -> Bool {
        if now == Date.distantFuture {
            return false
        } else {
            return instant.compare(now) == .orderedAscending
        }
    }

    func remainingFrom(_ now: Date) -> TimeAmount {
        let d = Int(instant.timeIntervalSince1970.rounded())
        let n = Int(now.timeIntervalSince1970.rounded())
        let delta = d - n
        return .milliseconds(delta)
    }
}
