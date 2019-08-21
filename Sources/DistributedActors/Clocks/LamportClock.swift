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

public typealias LamportTime = UInt64

/// A Lamport clock.
///
/// Each node or entity owns its own clock, and updates it each time
///
///
/// NOTE: Unless two events are causally related, lamport clocks are not able to guarantee causality,
///       and thus strict happens-before relationships.
///
/// - SeeAlso: <https://www.microsoft.com/en-us/research/publication/time-clocks-ordering-events-distributed-system/>
///            Time, Clocks, and the Ordering of Events in a Distributed System, Leslie Lamport, 1978</a>
public struct LamportClock: ExpressibleByIntegerLiteral {
    public typealias IntegerLiteralType = UInt64

    private var _time: LamportTime

    public init() {
        self._time = 0
    }

    public init(integerLiteral value: IntegerLiteralType) {
        self._time = LamportTime(value)
    }

    public var time: LamportTime {
        return self._time
    }

    public mutating func increment() {
        self._time += 1
    }

    /// Witnessing time may only move the clock *forward*.
    public mutating func witness(_ other: LamportClock) {
        self._time = max(self._time, other._time)
    }
}
