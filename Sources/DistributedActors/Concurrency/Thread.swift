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

import DistributedActorsConcurrencyHelpers
import NIO

enum ThreadError: Error {
    case threadCreationFailed
    case threadJoinFailed
}

private class BoxedClosure {
    let f: () -> Void

    init(f: @escaping () -> Void) {
        self.f = f
    }
}

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
final class Thread {
    internal typealias ThreadBoxValue = (body: (Thread) -> Void, name: String?)
    internal typealias ThreadBox = Box<ThreadBoxValue>

    private let desiredName: String?

    /// The thread handle used by this instance.
    private let handle: ThreadOpsSystem.ThreadHandle

    /// Create a new instance
    ///
    /// - arguments:
    ///     - handle: The `ThreadOpsSystem.ThreadHandle` that is wrapped and used by the `Thread`.
    internal init(handle: ThreadOpsSystem.ThreadHandle, desiredName: String?) {
        self.handle = handle
        self.desiredName = desiredName
    }

    /// Execute the given body with the `pthread_t` that is used by this `Thread` as argument.
    ///
    /// - warning: Do not escape `pthread_t` from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the `pthread_t`.
    /// - returns: The value returned by `body`.
    internal func withUnsafeThreadHandle<T>(_ body: (ThreadOpsSystem.ThreadHandle) throws -> T) rethrows -> T {
        try body(self.handle)
    }

    /// Get current name of the `Thread` or `nil` if not set.
    var currentName: String? {
        ThreadOpsSystem.threadName(self.handle)
    }

    func join() {
        ThreadOpsSystem.joinThread(self.handle)
    }

    /// Spawns and runs some task in a `Thread`.
    ///
    /// - arguments:
    ///     - name: The name of the `Thread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `Thread`.
    ///     - detach: Whether to detach the thread. If the thread is not detached it must be `join`ed.
    static func spawnAndRun(name: String? = nil, detachThread: Bool = true,
                            body: @escaping (Thread) -> Void) {
        var handle: ThreadOpsSystem.ThreadHandle?

        // Store everything we want to pass into the c function in a Box so we
        // can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)

        ThreadOpsSystem.run(handle: &handle, args: box, detachThread: detachThread)
    }

    /// Returns `true` if the calling thread is the same as this one.
    var isCurrent: Bool {
        ThreadOpsSystem.isCurrentThread(self.handle)
    }

    /// Returns the current running `Thread`.
    static var current: Thread {
        let handle = ThreadOpsSystem.currentThread
        return Thread(handle: handle, desiredName: nil)
    }
}

public func __sleep(_ amount: TimeAmount) {
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

public func __exit(code: inout Int) {
    pthread_exit(&code)
}

enum LowLevelThreadOperations {}

protocol ThreadOps {
    associatedtype ThreadHandle
    associatedtype ThreadSpecificKey
    associatedtype ThreadSpecificKeyDestructor

    static func threadName(_ thread: ThreadHandle) -> String?
    static func run(handle: inout ThreadHandle?, args: Box<Thread.ThreadBoxValue>, detachThread: Bool)
    static func isCurrentThread(_ thread: ThreadHandle) -> Bool
    static func compareThreads(_ lhs: ThreadHandle, _ rhs: ThreadHandle) -> Bool
    static var currentThread: ThreadHandle { get }
    static func joinThread(_ thread: ThreadHandle)
    static func allocateThreadSpecificValue(destructor: ThreadSpecificKeyDestructor) -> ThreadSpecificKey
    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey)
    static func getThreadSpecificValue(_ key: ThreadSpecificKey) -> UnsafeMutableRawPointer?
    static func setThreadSpecificValue(key: ThreadSpecificKey, value: UnsafeMutableRawPointer?)
}

public final class ThreadSpecificVariable<Value: AnyObject> {
    /* the actual type in there is `Box<(ThreadSpecificVariable<T>, T)>` but we can't use that as C functions can't capture (even types) */
    private typealias BoxedType = Box<(AnyObject, AnyObject)>

    internal class Key {
        private var underlyingKey: ThreadOpsSystem.ThreadSpecificKey

        internal init(destructor: @escaping ThreadOpsSystem.ThreadSpecificKeyDestructor) {
            self.underlyingKey = ThreadOpsSystem.allocateThreadSpecificValue(destructor: destructor)
        }

        deinit {
            ThreadOpsSystem.deallocateThreadSpecificValue(self.underlyingKey)
        }

        public func get() -> UnsafeMutableRawPointer? {
            ThreadOpsSystem.getThreadSpecificValue(self.underlyingKey)
        }

        public func set(value: UnsafeMutableRawPointer?) {
            ThreadOpsSystem.setThreadSpecificValue(key: self.underlyingKey, value: value)
        }
    }

    private let key: Key

    /// Initialize a new `ThreadSpecificVariable` without a current value (`currentValue == nil`).
    public init() {
        self.key = Key(destructor: {
            Unmanaged<BoxedType>.fromOpaque(($0 as UnsafeMutableRawPointer?)!).release()
        })
    }

    /// Initialize a new `ThreadSpecificVariable` with `value` for the calling thread. After calling this, the calling
    /// thread will see `currentValue == value` but on all other threads `currentValue` will be `nil` until changed.
    ///
    /// - parameters:
    ///   - value: The value to set for the calling thread.
    public convenience init(value: Value) {
        self.init()
        self.currentValue = value
    }

    /// The value for the current thread.
    public var currentValue: Value? {
        /// Get the current value for the calling thread.
        get {
            guard let raw = self.key.get() else { return nil }
            // parenthesize the return value to silence the cast warning
            return (Unmanaged<BoxedType>
                .fromOpaque(raw)
                .takeUnretainedValue()
                .value.1 as! Value)
        }

        /// Set the current value for the calling threads. The `currentValue` for all other threads remains unchanged.
        set {
            if let raw = self.key.get() {
                Unmanaged<BoxedType>.fromOpaque(raw).release()
            }
            self.key.set(value: newValue.map { Unmanaged.passRetained(Box((self, $0))).toOpaque() })
        }
    }
}

/// Allows to "box" another value.
@usableFromInline
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}
