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

import Foundation

#if os(OSX)
import Darwin
#else
import Glibc
#endif

/// Utilities to perform process management in an OS-agnostic way.
internal enum POSIXProcessUtils {

    /// - SeeAlso: http://man7.org/linux/man-pages/man3/posix_spawn.3.html
    /// - SeeAlso: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html
    public static func forkExec(command: String, args: [String]) throws -> Int {
        var pid: pid_t = 0

        #if os(OSX)
        var tid: pthread_t? = nil
        var childFDActions: posix_spawn_file_actions_t? = nil
        #else
        var tid = pthread_t()
        var childFDActions = posix_spawn_file_actions_t()
        #endif

        // TODO: rather than the polling ppid monitor we can use pipes between processes
        //       to detect when the parent has died to avoid zombies;
        // private var outputPipe: [Int32] = [-1, -1]

        posix_spawn_file_actions_init(&childFDActions)

        let status = args.withNULLTerminatedCArrayOfStrings { argv in
            posix_spawn(&pid, argv[0], &childFDActions, nil, argv, nil)
        }

        if status < 0 {
            throw SpawnError("Could not posix_spawn [\(command)]")
        }

        return Int(pid)
    }

    /// Get PID of parent process.
    internal static func getParentPID() -> Int {
        return Int(getppid())
    }

    /// Exits the current process.
    ///
    /// Exposed here we do not need to import Darwin/Glibc.
    internal static func _exit(_ code: Int32) {
        exit(code)
    }

    internal static func nonBlockingWaitPID(pid: Int, opts _opts: Int32 = 0) -> WaitPidResult {
        var status: Int32 = 0

        let opts = _opts | WNOHANG
        let _pid = waitpid(Int32(pid), &status, opts)

        return .init(pid: Int(_pid), status: Int(status))
    }
    internal struct WaitPidResult {
        let pid: Int
        let status: Int
    }

    struct SpawnError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }
}

extension Array where Element == String {
    internal func withNULLTerminatedCArrayOfStrings<T>(_ body: @escaping (UnsafePointer<UnsafeMutablePointer<Int8>?>) -> T) -> T {
        func appendPointer(_ index: Array.Index, to target: inout Array<UnsafeMutablePointer<Int8>?>) -> T {
            if index == self.endIndex {
                target.append(nil)
                return body(&target)
            } else {
                return self[index].withCString { cStringPtr in
                    target.append(UnsafeMutablePointer<Int8>(mutating: cStringPtr))
                    return appendPointer(self.index(after: index), to: &target)
                }
            }
        }

        var elements = Array<UnsafeMutablePointer<Int8>?>()
        elements.reserveCapacity(self.count + 1)

        return appendPointer(self.startIndex, to: &elements)
    }
}
