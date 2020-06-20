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

import DistributedActorsConcurrencyHelpers
import Foundation

/// A FixedThreadPool eagerly starts the configured number of threads and keeps
/// all of them running until `shutdown` is called. Submitted tasks will be
/// executed concurrently on all threads.
public final class FixedThreadPool {
    @usableFromInline
    internal let q: LinkedBlockingQueue<() -> Void> = LinkedBlockingQueue()
    private var workers: [Worker] = []

    @usableFromInline
    internal let stopping: Atomic<Bool> = Atomic(value: false)

    @usableFromInline
    internal let runningWorkers: Atomic<Int>

    internal let allThreadsStopped: BlockingReceptacle<Void> = BlockingReceptacle()

    public init(_ threadCount: Int) throws {
        self.runningWorkers = Atomic(value: threadCount)

        for n in 1 ... threadCount {
            let worker = Worker(name: "FixedThreadPool-\(n)") { lock in
                while !self.stopping.load() {
                    // FIXME: We are currently using a timed `poll` instead of indefinitely
                    //        blocking on `dequeue` because we need to be able to check
                    //        if the pool is stopping. `pthread_cancel` is problematic here
                    //        because if a thread is waiting on a `pthread_cond_t`, it will
                    //        re-acquire the mutex before cancelation, which is almost
                    //        guaranteed to cause a deadlock.
                    if let runnable = self.q.poll(.milliseconds(100)) {
                        lock.lock()
                        defer { lock.unlock() }
                        runnable()
                    }
                }

                if self.runningWorkers.sub(1) == 1 {
                    // the last thread that stopped notifies the thread(s) waiting for the shutdown
                    self.allThreadsStopped.offerOnce(())
                }
            }

            self.workers.append(worker)
        }
    }

    /// Initiates shutdown of the pool. Active threads will complete processing
    /// of the current work item, idle threads will complete immediately.
    /// Outstanding work items that have not started processing will not be
    /// ignored.
    public func shutdown() {
        if !self.stopping.exchange(with: true) {
            self.workers.removeAll()
            self.q.clear()
            self.allThreadsStopped.wait()
        }
    }

    /// Submits a task to the threadpool. The task will be asynchronously
    /// processed by one of the threads in the pool.
    ///
    /// - Parameter task: The task to be processed.
    @inlinable
    public func submit(_ task: @escaping () -> Void) {
        if !self.stopping.load() {
            self.q.enqueue(task)
        }
    }
}

extension FixedThreadPool {
    private final class Worker {
        @usableFromInline
        let _lock: _Mutex

        init(name: String, _ closure: @escaping (_Mutex) -> Void) {
            self._lock = _Mutex()
            Thread.spawnAndRun(name: name) { _ in
                closure(self._lock)
            }
        }

        @inlinable
        func lock() {
            self._lock.lock()
        }

        @inlinable
        func tryLock() -> Bool {
            self._lock.tryLock()
        }

        @inlinable
        func unlock() {
            self._lock.unlock()
        }
    }
}
