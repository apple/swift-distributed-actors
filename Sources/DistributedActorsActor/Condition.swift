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

public final class Condition {
    @usableFromInline
    var condition: pthread_cond_t = pthread_cond_t()

    public init() {
        let error = pthread_cond_init(&condition, nil)

        switch error {
        case 0:
            return
        default:
            fatalError("Condition could not be created: \(error)")
        }
    }

    deinit {
        pthread_cond_destroy(&condition)
    }

    @inlinable
    public func wait(_ mutex: Mutex) -> Void {
        let error = pthread_cond_wait(&condition, &mutex.mutex)

        switch error {
        case 0:
            return
        case EPERM:
            fatalError("Wait failed, mutex is not owned by this thread")
        case EINVAL:
            fatalError("Wait failed, condition is not valid")
        default:
            fatalError("Wait failed with unspecified error: \(error)")
        }
    }

    @inlinable
    public func wait(_ mutex: Mutex, amount: TimeAmount) -> Bool {
//    clock_gettime(CLOCK_REALTIME, &now)
//    let reltime = sleep_til_this_absolute_time - now;

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let time = TimeSpec.from(timeAmount: amount)
        #else
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let time = now + TimeSpec.from(timeAmount: amount)
        #endif
        let error = withUnsafePointer(to: time, { p -> Int32 in
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            return pthread_cond_timedwait_relative_np(&condition, &mutex.mutex, p)
            #else
            return pthread_cond_timedwait(&condition, &mutex.mutex, p)
            #endif
        })

        switch error {
        case 0:
            return true
        case ETIMEDOUT:
            return false
        case EPERM:
            fatalError("Wait failed, mutex is not owned by this thread")
        case EINVAL:
            fatalError("Wait failed, condition is not valid")
        default:
            fatalError("Wait failed with unspecified error: \(error)")
        }
    }

    @inlinable
    public func signal() -> Void {
        let error = pthread_cond_signal(&condition)

        switch error {
        case 0:
            return
        case EINVAL:
            fatalError("Signal failed, condition is not valid")
        default:
            fatalError("Signal failed with unspecified error: \(error)")
        }
    }
}
