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
import Atomics

@usableFromInline
internal enum AffinityThreadPoolError: Error {
    case unknownWorker(workerNumber: Int)
}

/// Allows work to be dispatched onto a specific thread
@usableFromInline
internal final class AffinityThreadPool {
    @usableFromInline
    internal let workers: [Worker]
    @usableFromInline
    internal let workerCount: Int
    @usableFromInline
    internal let stopped: ManagedAtomic<Bool>

    internal init(workerCount: Int) throws {
        var workers: [Worker] = []
        self.workerCount = workerCount
        self.stopped = .init(false)

        for _ in 0 ..< workerCount {
            workers.append(try Worker(stopped: self.stopped))
        }

        self.workers = workers
    }

    deinit {
//        self.stopped.destroy()
    }

    /// Executes `task` on the specified worker thread.
    ///
    /// - Parameters:
    ///   - workerNumber: number of the worker to execute `task` on
    ///   - task: the task to be executed
    /// - Throws:
    ///   - AffinityThreadPoolError.unknownWorker, when no worker exists for `workerNumber`
    @inlinable
    internal func execute(on workerNumber: Int, _ task: @escaping () -> Void) throws {
        guard workerNumber < self.workerCount else {
            throw AffinityThreadPoolError.unknownWorker(workerNumber: workerNumber)
        }

        self.workers[workerNumber].taskQueue.enqueue(task)
    }

    /// Causes all threads in this pool to stop. Task that are currently being
    /// processed will be finished, but no new tasks will be started.
    @inlinable
    internal func shutdown() {
        self.stopped.store(true, ordering: .releasing)
    }

    @usableFromInline
    internal struct Worker {
        @usableFromInline
        internal let taskQueue: _LinkedBlockingQueue<() -> Void>
        private let thread: _Thread

        internal init(stopped: ManagedAtomic<Bool>) throws {
            let queue: _LinkedBlockingQueue<() -> Void> = _LinkedBlockingQueue()
            let thread = try _Thread {
                while !stopped.load(ordering: .acquiring) {
                    // TODO: We are doing a timed poll here to guarantee that we
                    // will eventually check if stopped has been set, even if no
                    // tasks are being processed. There must be a better way to
                    // guarantee shutdown will properly stop. Java uses interrupts,
                    // but that does not seem to be an option here.
                    if let task = queue.poll(.milliseconds(100)) {
                        task()
                    }
                }
            }
            self.thread = thread
            self.taskQueue = queue
        }
    }
}
