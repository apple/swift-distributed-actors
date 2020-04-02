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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

import NIO

// MARK: utilities to convert between TimeAmount and C timespec

private let NANOS = 1_000_000_000

/// :nodoc: Not intended for general use. TODO: Make internal if possible.
public typealias TimeSpec = timespec

// TODO: move to Time.swift?

/// :nodoc: Not intended for general use. TODO: Make internal if possible.
public extension TimeSpec {
    static func from(timeAmount amount: TimeAmount) -> timespec {
        let seconds = Int(amount.nanoseconds) / NANOS
        let nanos = Int(amount.nanoseconds) % NANOS
        var time = timespec()
        time.tv_sec = seconds
        time.tv_nsec = nanos
        return time
    }

    static func + (a: timespec, b: timespec) -> timespec {
        let totalNanos = a.toNanos() + b.toNanos()
        let seconds = totalNanos / NANOS
        var result = timespec()
        result.tv_sec = seconds
        result.tv_nsec = totalNanos % NANOS
        return result
    }

    func toNanos() -> Int {
        self.tv_nsec + (self.tv_sec * NANOS)
    }
}

extension TimeSpec: Comparable {
    public static func < (lhs: TimeSpec, rhs: TimeSpec) -> Bool {
        lhs.tv_sec < rhs.tv_sec || (lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec < rhs.tv_nsec)
    }

    public static func == (lhs: TimeSpec, rhs: TimeSpec) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == lhs.tv_nsec
    }
}
