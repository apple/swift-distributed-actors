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

#if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif

#if os(iOS) || os(watchOS) || os(tvOS)
// not supported on these operating systems
#else
/// Utilities to perform process management in an OS-agnostic way.
internal enum POSIXProcessUtils {
    /// - SeeAlso: http://man7.org/linux/man-pages/man3/posix_spawn.3.html
    /// - SeeAlso: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html
    /// - SeeAlso: https://github.com/apple/swift-corelibs-foundation/blob/main/Foundation/Process.swift
    public static func spawn(command: String, args argv: [String]) throws -> Int {
        // pid
        var pid = pid_t()

        #if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
        // var tid: pthread_t?
        var childFDActions: posix_spawn_file_actions_t?
        #else
        // var tid = pthread_t()
        var childFDActions = posix_spawn_file_actions_t()
        #endif

        // env

        let env: [String: String] = ProcessInfo.processInfo.environment

        let nenv = env.count
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: 1 + nenv)
        envp.initialize(
            from: env.map {
                strdup("\($0)=\($1)")
            },
            count: nenv
        )
        envp[env.count] = nil

        defer {
            for pair in envp ..< envp + env.count {
                if let pointee = pair.pointee {
                    free(UnsafeMutableRawPointer(pointee))
                }
            }
            envp.deallocate()
        }

        // Socket pair
        // TODO: use socket pair for failure detection rather than the current polling

        var taskSocketPair: [Int32] = [0, 0]
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        socketpair(AF_UNIX, SOCK_STREAM, 0, &taskSocketPair)
        #else
        socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &taskSocketPair)
        #endif

        // ==== closing fds ------------------------------------------------
        // We close all file descriptors in the child process.
        posix_spawn_file_actions_init(&childFDActions)

        // closing fds ------------
        // We close all file descriptors in the child process.

        // (METHOD 1) -- add to file actions all FDs -- linux likes this and Darwin is a bit weird and we get EBADF when spawning then
        // TODO: This breaks on macOS, since posix_spawn wrongly returns the `EBADF` from `close_nocancel`, even though this is not documented (!)
        // TODO: create a radar to discuss this
//        // from 3 since stdout(1)/stderr(2)
//        for fd in 3 ..< getdtablesize() {
//            switch posix_spawn_file_actions_addclose(&childFDActions, fd) {
//            case 0:
//                () // OK
//            case EBADF:
//                fatalError("Bad file descriptor: \(fd)")
//            case EINVAL:
//                fatalError("Value invalid: \(fd)")
//            case ENOMEM:
//                fatalError("Insufficient memory exists to add to the spawn file actions object: \(fd)")
//            default:
//                fatalError("Unknown error; Trying to addclose file descriptor: \(fd)")
//            }
//        }

        // TODO: This has global effects and we would prefer to use (METHOD 1),
        // Alternative method, though has global effects, on any process spawn, not only ones managed by the actor system.
        for fd in 3 ..< getdtablesize() {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        // end of closing fds -----

        // Spawn

        let status = argv.withNULLTerminatedCArrayOfStrings { argv in
            posix_spawn(&pid, argv[0]!, &childFDActions, nil, argv, envp)
        }

        guard status == 0 else {
            throw SpawnError("Could not posix_spawn [\(command)]; Error status code: \(status)")
        }

        close(taskSocketPair[1])

        return Int(pid)
    }

    /// Get PID of parent process.
    internal static func getParentPID() -> Int {
        Int(getppid())
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
        func appendPointer(_ index: Array.Index, to target: inout [UnsafeMutablePointer<Int8>?]) -> T {
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

        var elements = [UnsafeMutablePointer<Int8>?]()
        elements.reserveCapacity(self.count + 1)

        return appendPointer(self.startIndex, to: &elements)
    }
}
#endif
