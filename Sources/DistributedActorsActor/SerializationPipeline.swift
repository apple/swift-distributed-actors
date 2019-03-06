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
import NIO

// TODO: We may eventually factor out the threadpool logic and turn it into a
// standalone threadpool that supports assigning work to a specific thread with
// configurable work stealing capabilities. For more info see #408
internal final class SerializationPipeline {
    internal let workerCount: Int
    internal let workers: [SerializationWorker]
    internal let serialization: Serialization
    internal let stopped: Atomic<Bool>

    internal init(workerCount: Int, serialization: Serialization) throws {
        self.workerCount = workerCount
        var workers: [SerializationWorker] = []
        for _ in 0 ..< workerCount {
            workers.append(try SerializationWorker())
        }

        self.workers = workers
        self.serialization = serialization
        self.stopped = Atomic(value: false)
    }

    deinit {
        self.shutdown()
    }

    func shutdown() {
        if !self.stopped.compareAndExchange(expected: false, desired: true) {
            for worker in self.workers {
                worker.stop()
            }
        }
    }

    func serialize<M>(message: M, recepientPath: ActorPath, promise: EventLoopPromise<ByteBuffer>) {
        self.enqueue(recepientPath: recepientPath, promise: promise) {
            try self.serialization.serialize(message: message)
        }
    }

    func deserialize<M>(to: M.Type, bytes: ByteBuffer, recepientPath: ActorPath, promise: EventLoopPromise<M>) {
        self.enqueue(recepientPath: recepientPath, promise: promise) {
            try self.serialization.deserialize(to: to, bytes: bytes)
        }
    }

    private func enqueue<T>(recepientPath: ActorPath, promise: EventLoopPromise<T>, f: @escaping () throws -> T) {
        let workerNumber = SerializationPipeline.workerHash(path: recepientPath, workerCount: self.workerCount)
        let worker = self.workers[workerNumber]
        worker.queue.enqueue {
            do {
                let result = try f()
                promise.succeed(result: result)
            } catch {
                promise.fail(error: error)
            }
        }
    }

    internal static func workerHash(path: ActorPath, workerCount: Int) -> Int {
        return abs(path.hashValue) % workerCount
    }
}

internal final class SerializationWorker {
    internal let queue: LinkedBlockingQueue<() -> Void>
    internal let thread: Thread
    internal let stopped: Atomic<Bool>

    internal init() throws {
        let queue: LinkedBlockingQueue<() -> Void> = LinkedBlockingQueue()
        let stopped = Atomic(value: false)
        let thread = try Thread {
            while !stopped.load(order: .acquire) {
                if let item = queue.poll(.milliseconds(10)) {
                    item()
                }
            }
        }

        self.thread = thread
        self.queue = queue
        self.stopped = stopped
    }

    internal func stop() {
        self.stopped.store(true, order: .release)
    }
}
