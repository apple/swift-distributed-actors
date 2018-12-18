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

import NIOConcurrencyHelpers
import Foundation

internal final class Worker {
    var thread: Thread? = nil
    var completedTasks: Int = 0

    private let _lock: Mutex = Mutex()

    func lock() {
        self._lock.lock()
    }

    func tryLock() -> Bool {
        return self._lock.tryLock()
    }

    func unlock() {
        return self._lock.unlock()
    }
}

public final class FixedThreadPool: StoppableMessageDispatcher {
    public var name: String {
        return _hackyPThreadThreadId()
    }

    @usableFromInline
    let q: LinkedBlockingQueue<() -> Void> = LinkedBlockingQueue()
    private var workers: [Worker] = []

    @usableFromInline
    internal var stopping: Atomic<Bool> = Atomic(value: false)

    public init(_ threadCount: Int) throws {
        for _ in 1...threadCount {
            let worker = Worker()
            let thread = try Thread {
                while !self.stopping.load() {
                    if let runnable = self.q.poll(.milliseconds(100)) {
                        worker.lock()
                        defer { worker.unlock() }
                        runnable()
                    }
                }
            }
            worker.thread = thread

            self.workers.append(worker)
        }
    }

    public func shutdown() throws -> Void {
        if !stopping.exchange(with: true) {
            workers.removeAll()
            q.clear()
        }
    }

    @inlinable
    public func submit(_ f: @escaping () -> Void) -> Void {
        if !stopping.load() {
            q.enqueue(f)
        }
    }

    @inlinable
    public func execute(_ f: @escaping () -> Void) {
        submit(f)
    }
}
