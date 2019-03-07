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

import NIO

// TODO: We may eventually factor out the threadpool logic and turn it into a
// standalone threadpool that supports assigning work to a specific thread with
// configurable work stealing capabilities. For more info see #408
internal final class SerializationPipeline {
    @usableFromInline
    internal let serialization: Serialization
    @usableFromInline
    internal let pipelineMapping: [ActorPath: Int]
    @usableFromInline
    internal let serializationWorkerPool: AffinityThreadPool
    @usableFromInline
    internal let deserializationWorkerPool: AffinityThreadPool

    internal init(props: SerializationPipelineProps, serialization: Serialization) throws {
        self.serialization = serialization
        var pipelineMapping: [ActorPath: Int] = [:]
        for (index, group) in props.serializationGroups.enumerated() {
            for path in group {
                // mapping from each actor path to the corresponding group index,
                // which maps 1:1 to the serialization worker number
                pipelineMapping[path] = index
            }
        }
        self.pipelineMapping = pipelineMapping
        self.serializationWorkerPool = try AffinityThreadPool(workerCount: props.serializationGroups.count)
        self.deserializationWorkerPool = try AffinityThreadPool(workerCount: props.serializationGroups.count)
    }

    deinit {
        self.shutdown()
    }

    internal func shutdown() {
        self.serializationWorkerPool.shutdown()
    }

    @inlinable
    internal func serialize<M>(message: M, recepientPath: ActorPath, promise: EventLoopPromise<ByteBuffer>) {
        self.enqueue(recepientPath: recepientPath, promise: promise, workerPool: self.serializationWorkerPool) {
            try self.serialization.serialize(message: message)
        }
    }

    @inlinable
    internal func deserialize<M>(as type: M.Type, bytes: ByteBuffer, recepientPath: ActorPath, promise: EventLoopPromise<M>) {
        self.enqueue(recepientPath: recepientPath, promise: promise, workerPool: self.deserializationWorkerPool) {
            try self.serialization.deserialize(as: type, bytes: bytes)
        }
    }

    private func enqueue<T>(recepientPath: ActorPath, promise: EventLoopPromise<T>, workerPool: AffinityThreadPool, task: @escaping () throws -> T) {
        do {
            // check if messages for this particular actor should be handled
            // on a separate thread and submit to the worker pool
            if let workerNumber = self.pipelineMapping[recepientPath] {
                try workerPool.execute(on: workerNumber) {
                    do {
                        let result = try task()
                        promise.succeed(result: result)
                    } catch {
                        promise.fail(error: error)
                    }
                }
            } else { // otherwise handle on the calling thread
                promise.succeed(result: try task())
            }
        } catch {
            promise.fail(error: error)
        }
    }
}

public struct SerializationPipelineProps {
    public let serializationGroups: [[ActorPath]]

    internal static var `default`: SerializationPipelineProps {
        return SerializationPipelineProps(serializationGroups: [])
    }
}
