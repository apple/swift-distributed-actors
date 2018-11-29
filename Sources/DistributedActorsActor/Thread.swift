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

public enum ThreadError: Error {
    case threadCreationFailed
    case threadJoinFailed
}

private class BoxedClosure {
    let f: () -> Void

    init(f: @escaping () -> Void) {
        self.f = f
    }
}

public class Thread {
    private let thread: pthread_t

    public init(_ f: @escaping () -> Void) throws {
        let ref = Unmanaged.passRetained(BoxedClosure(f: f))

        #if os(Linux)
        var t: pthread_t = pthread_t()
        #else
        var t: pthread_t?
        #endif

        guard pthread_create(&t, nil, runnerCallback, ref.toOpaque()) == 0 else {
            ref.release()
            throw ThreadError.threadCreationFailed
        }

        #if os(Linux)
        thread = t
        #else
        thread = t!
        #endif
    }

    public func join() throws {
        let status = pthread_join(thread, nil)
        if status != 0 {
            throw ThreadError.threadJoinFailed
        }
    }

    public func cancel() -> Void {
        let error = pthread_cancel(thread)

        switch error {
        case 0:
            return
        case ESRCH:
            fatalError("Cancel failed because no thread could be found with id: \(thread)")
        default:
            fatalError("Cancel failed with unspecified error: \(error)")
        }
    }

    deinit {
        pthread_detach(thread)
    }

    public static func sleep(_ amount: TimeAmount) -> Void {
        var time = TimeSpec.from(timeAmount: amount)
        let err = nanosleep(&time, nil)
        if err != 0 {
            switch errno {
            case EFAULT:
                fatalError("Sleep failed because the information could not be copied")
            case EINVAL:
                fatalError("Sleep failed because of invalid data")
            case EINTR:
                fatalError("Sleep failed because fo an interrupt")
            default:
                fatalError("Sleep failed with unspecified error: \(err)")
            }
        }
    }

    public static func exit(code: inout Int) {
        pthread_exit(&code)
    }
}

#if os(Linux)
typealias CRunnerCallback = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
#else
typealias CRunnerCallback = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
#endif

private var runnerCallback: CRunnerCallback {
    return { arg in
        let unmanaged: Unmanaged<BoxedClosure>
        #if os(Linux)
        unmanaged = Unmanaged<BoxedClosure>.fromOpaque(arg!)
        #else
        unmanaged = Unmanaged<BoxedClosure>.fromOpaque(arg)
        #endif
        unmanaged.takeUnretainedValue().f()
        unmanaged.release()
        return nil
    }
}
