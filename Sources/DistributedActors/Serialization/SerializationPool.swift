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

/// A pool of serialization worker threads which perform (de)serialization of messages potentially in parallel.
/// The main purpose of doing so rather than serializing directly inside the calling thread (e.g. the event loop)
/// is offloading serializing potentially "heavy" messages from others which are small and quick to (de)serialize.
///
/// Conceptually serialization is performed on dedicated "lanes" which correspond to the recipient of the message.
/// Dedicated lanes for recipient actors can be configured using `SerializationPoolSettings`.
/// // TODO the scheme how we configure this may need some more re-thinking.
///
/// Dispatching serialization to workers comes with a latency hit, as more async-processing has to happen to perform the
/// same amount of work, however it allows avoiding head-of-line blocking in presence of large messages, e.g. when typically
/// a given set of actors often sends large messages, which would have otherwise stalled the sending of other high-priority
/// (e.g. system) messages.
///
// Implementation note: This should be internal, but is forced to be public by `_deserializeDeliver`
public final class SerializationPool {
    @usableFromInline
    internal let serialization: Serialization
    @usableFromInline
    internal let workerMapping: [ActorPath: Int]
    @usableFromInline
    internal let serializationWorkerPool: AffinityThreadPool
    @usableFromInline
    internal let deserializationWorkerPool: AffinityThreadPool

    @usableFromInline
    internal let instrumentation: ActorTransportInstrumentation

    internal init(settings: SerializationPoolSettings, serialization: Serialization, instrumentation: ActorTransportInstrumentation? = nil) throws {
        self.serialization = serialization
        self.instrumentation = instrumentation ?? NoopActorTransportInstrumentation()
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
    internal func serialize(
        message: Any,
        recipientPath: ActorPath,
        promise: EventLoopPromise<(Serialization.Manifest, ByteBuffer)>
    ) {
        // TODO: also record thr delay between submitting and starting serialization work here?
        self.enqueue(recipientPath: recipientPath, promise: promise, workerPool: self.serializationWorkerPool) {
            do {
                self.instrumentation.remoteActorMessageSerializeStart(id: promise.futureResult, recipient: recipientPath, message: message)
                let (manifest, bytes) = try self.serialization.serialize(message)

                // TODO: collapse those two and only use the instrumentation points, also for metrics
                self.instrumentation.remoteActorMessageSerializeEnd(id: promise.futureResult, bytes: bytes.readableBytes)
                self.serialization.metrics.recordSerializationMessageOutbound(recipientPath, bytes.readableBytes)

                return (manifest, bytes)
            } catch {
                self.instrumentation.remoteActorMessageSerializeEnd(id: promise.futureResult, bytes: 0)
                throw error
            }
        }
    }

    @inlinable
    internal func deserialize<Message>(
        as messageType: Message.Type,
        from _bytes: ByteBuffer,
        using manifest: Serialization.Manifest,
        recipientPath: ActorPath,
        promise: EventLoopPromise<Message>
    ) {
        // TODO: also record thr delay between submitting and starting serialization work here?
        self.enqueue(recipientPath: recipientPath, promise: promise, workerPool: self.deserializationWorkerPool) {
            do {
                self.serialization.metrics.recordSerializationMessageInbound(recipientPath, _bytes.readableBytes)
                self.instrumentation.remoteActorMessageDeserializeStart(id: promise.futureResult, recipient: recipientPath, bytes: _bytes.readableBytes)

                var bytes = _bytes
                // do the work, this may be "heavy"
                let deserialized = try self.serialization.deserialize(as: messageType, from: &bytes, using: manifest)

                self.instrumentation.remoteActorMessageDeserializeEnd(id: promise.futureResult, message: deserialized)
                return deserialized
            } catch {
                self.instrumentation.remoteActorMessageDeserializeEnd(id: promise.futureResult, message: nil)
                throw error
            }
        }
    }

    @inlinable
    internal func deserialize<Message>(
        as messageType: Message.Type,
        from _bytes: ByteBuffer,
        using manifest: Serialization.Manifest,
        recipientPath: ActorPath,
        // The only reason we use a wrapper instead of raw function is that (...) -> () do not have identity,
        // and we use identity of the callback to interact with the instrumentation for start/stop correlation.
        callback: DeserializationCallback<Message>
    ) {
        self.enqueue(recipientPath: recipientPath, onComplete: { callback.call($0) }, workerPool: self.deserializationWorkerPool) {
            do {
                var bytes = _bytes
                self.serialization.metrics.recordSerializationMessageInbound(recipientPath, bytes.readableBytes)
                self.instrumentation.remoteActorMessageDeserializeStart(id: callback, recipient: recipientPath, bytes: bytes.readableBytes)

                // do the work, this may be "heavy"
                let deserialized = try self.serialization.deserialize(as: messageType, from: &bytes, using: manifest)

                self.instrumentation.remoteActorMessageDeserializeEnd(id: callback, message: deserialized)
                return deserialized
            } catch {
                self.instrumentation.remoteActorMessageDeserializeEnd(id: callback, message: nil)
                throw error
            }
        }
    }

    @inline(__always)
    @usableFromInline
    internal func enqueue<Message>(
        recipientPath: ActorPath,
        promise: EventLoopPromise<Message>,
        workerPool: AffinityThreadPool,
        task: @escaping () throws -> Message
    ) {
        self.enqueue(recipientPath: recipientPath, onComplete: promise.completeWith, workerPool: workerPool, task: { try task() })
    }

    @inline(__always)
    @usableFromInline
    internal func enqueue<Message>(
        recipientPath: ActorPath,
        onComplete: @escaping (Result<Message, Error>) -> Void,
        workerPool: AffinityThreadPool,
        task: @escaping () throws -> Message
    ) {
        // TODO: also record thr delay between submitting and starting serialization work here?
        do {
            // check if messages for this particular actor should be handled
            // on a separate thread and submit to the worker pool
            if let workerNumber = self.workerMapping[recipientPath] {
                try workerPool.execute(on: workerNumber) {
                    do {
                        onComplete(.success(try task()))
                    } catch {
                        onComplete(.failure(error))
                    }
                }
            } else { // otherwise handle on the calling thread
                onComplete(.success(try task()))
            }
        } catch {
            onComplete(.failure(error))
        }
    }
}

/// Allows to "box" another value.
@usableFromInline
final class DeserializationCallback<Message> {
    @usableFromInline
    let call: (Result<Message, Error>) -> Void
    init(_ callback: @escaping (Result<Message, Error>) -> Void) { self.call = callback }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization.Settings

public struct SerializationPoolSettings {
    public let serializationGroups: [[ActorPath]]

    internal static var `default`: SerializationPoolSettings {
        SerializationPoolSettings(serializationGroups: [])
    }
}
