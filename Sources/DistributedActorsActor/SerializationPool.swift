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

internal final class SerializationPool {
    @usableFromInline
    internal let serialization: Serialization
    @usableFromInline
    internal let workerMapping: [ActorPath: Int]
    @usableFromInline
    internal let serializationWorkerPool: AffinityThreadPool
    @usableFromInline
    internal let deserializationWorkerPool: AffinityThreadPool

    internal init(settings: SerializationPoolSettings, serialization: Serialization) throws {
        self.serialization = serialization
        var workerMapping: [ActorPath: Int] = [:]
        for (index, group) in settings.serializationGroups.enumerated() {
            for path in group {
                // mapping from each actor path to the corresponding group index,
                // which maps 1:1 to the serialization worker number
                workerMapping[path] = index
            }
        }
        self.workerMapping = workerMapping
        self.serializationWorkerPool = try AffinityThreadPool(workerCount: settings.serializationGroups.count)
        self.deserializationWorkerPool = try AffinityThreadPool(workerCount: settings.serializationGroups.count)
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
    internal func serialize(message: Any, metaType: AnyMetaType, recepientPath: ActorPath, promise: EventLoopPromise<(Serialization.SerializerId, ByteBuffer)>) {
        self.enqueue(recepientPath: recepientPath, promise: promise, workerPool: self.serializationWorkerPool) {
            try self.serialization.serialize(message: message, metaType: metaType)
        }
    }

    @inlinable
    internal func deserialize<M>(_ type: M.Type, from bytes: ByteBuffer, recepientPath: ActorPath, promise: EventLoopPromise<M>) {
        // TODO bytes to become inout?
        self.enqueue(recepientPath: recepientPath, promise: promise, workerPool: self.deserializationWorkerPool) {
            try self.serialization.deserialize(type, from: bytes)
        }
    }

    @inlinable
    internal func deserialize(serializerId: Serialization.SerializerId, from bytes: ByteBuffer, recepientPath: ActorPath, promise: EventLoopPromise<Any>) {
        // TODO bytes to become inout?
        self.enqueue(recepientPath: recepientPath, promise: promise, workerPool: self.deserializationWorkerPool) {
            try self.serialization.deserialize(serializerId: serializerId, from: bytes)
        }
    }

    private func enqueue<T>(recepientPath: ActorPath, promise: EventLoopPromise<T>, workerPool: AffinityThreadPool, task: @escaping () throws -> T) {
        do {
            // check if messages for this particular actor should be handled
            // on a separate thread and submit to the worker pool
            if let workerNumber = self.workerMapping[recepientPath] {
                try workerPool.execute(on: workerNumber) {
                    do {
                        let result = try task()
                        promise.succeed(result)
                    } catch {
                        promise.fail(error)
                    }
                }
            } else { // otherwise handle on the calling thread
                promise.succeed(try task())
            }
        } catch {
            promise.fail(error)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SerializationSettings

public struct SerializationPoolSettings {
    public let serializationGroups: [[ActorPath]]

    internal static var `default`: SerializationPoolSettings {
        return SerializationPoolSettings(serializationGroups: [])
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SerializationEnvelope

struct SerializationEnvelope {
    let message: Any
    let recipient: UniqueActorPath
    let metaType: AnyMetaType

    init<M>(message: M, recipient: UniqueActorPath) {
        self.message = message
        self.recipient = recipient
        self.metaType = MetaType(M.self)
    }
}
