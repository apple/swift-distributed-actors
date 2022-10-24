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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

import NIO

// MARK: utilities to convert between Duration and C timespec

private let NANOS = 1_000_000_000

/// Not intended for general use. TODO: Make internal if possible.
@usableFromInline
internal typealias TimeSpec = timespec

// TODO: move to Time.swift?

/// Not intended for general use. TOD
extension TimeSpec {
    @usableFromInline
    internal static func from(duration: Duration) -> timespec {
        let seconds = Int(duration.nanoseconds) / NANOS
        let nanos = Int(duration.nanoseconds) % NANOS
        var time = timespec()
        time.tv_sec = seconds
        time.tv_nsec = nanos
        return time
    }

    @usableFromInline
    internal static func + (a: timespec, b: timespec) -> timespec {
        let totalNanos = a.toNanos() + b.toNanos()
        let seconds = totalNanos / NANOS
        var result = timespec()
        result.tv_sec = seconds
        result.tv_nsec = totalNanos % NANOS
        return result
    }

    @usableFromInline
    internal func toNanos() -> Int {
        self.tv_nsec + (self.tv_sec * NANOS)
    }
}
