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

import Atomics
import DistributedActorsConcurrencyHelpers
import Foundation

// TODO: Discuss naming of `Worker`
private final class Worker {
    var thread: _Thread?
    var completedTasks: Int = 0

    @usableFromInline
    let _lock: _Mutex = .init()

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

/// A FixedThreadPool eagerly starts the configured number of threads and keeps
/// all of them running until `shutdown` is called. Submitted tasks will be
/// executed concurrently on all threads.
// FIXME(swift): very simple thread pool, does not need to be great since we're moving entirely to swift built-in runtime
public final class _FixedThreadPool {
    @usableFromInline
    internal let q: _LinkedBlockingQueue<() -> Void> = _LinkedBlockingQueue()
    private var workers: [Worker] = []

    @usableFromInline
    internal let stopping: ManagedAtomic<Bool>

    @usableFromInline
    internal let runningWorkers: ManagedAtomic<Int>

    internal let allThreadsStopped: BlockingReceptacle<Void> = BlockingReceptacle()

    public init(_ threadCount: Int) throws {
        self.stopping = .init(false)
        self.runningWorkers = .init(threadCount)

        for _ in 1 ... threadCount {
            let worker = Worker()
            let thread = try _Thread {
                // threads in the pool keep running as long as the pool is not stopping
                while !self.stopping.load(ordering: .relaxed) {
                    // FIXME: We are currently using a timed `poll` instead of indefinitely
                    //        blocking on `dequeue` because we need to be able to check
                    //        if the pool is stopping. `pthread_cancel` is problematic here
                    //        because if a thread is waiting on a `pthread_cond_t`, it will
                    //        re-acquire the mutex before cancelation, which is almost
                    //        guaranteed to cause a deadlock.
                    if let runnable = self.q.poll(.milliseconds(100)) {
                        worker.lock()
                        defer { worker.unlock() }
                        runnable()
                        worker.completedTasks += 1
                    }
                }

                if self.runningWorkers.loadThenWrappingDecrement(ordering: .relaxed) == 1 {
                    // the last thread that stopped notifies the thread(s) waiting for the shutdown
                    self.allThreadsStopped.offerOnce(())
                }
            }
            worker.thread = thread

            self.workers.append(worker)
        }
    }

    deinit {
//        self.stopping.destroy()
//        self.runningWorkers.destroy()
    }

    /// Initiates shutdown of the pool. Active threads will complete processing
    /// of the current work item, idle threads will complete immediately.
    /// Outstanding work items that have not started processing will not be
    /// ignored.
    public func shutdown() {
        if !self.stopping.exchange(true, ordering: .relaxed) {
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
        if !self.stopping.load(ordering: .relaxed) {
            self.q.enqueue(task)
        }
    }
}
