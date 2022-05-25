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
// TODO: This should be internal, but is forced to be public by `_deserializeDeliver` on references.
public final class _SerializationPool {
    @usableFromInline
    internal let serialization: Serialization
    @usableFromInline
    internal let workerMapping: [String: Int]
    @usableFromInline
    internal let serializationWorkerPool: AffinityThreadPool
    @usableFromInline
    internal let deserializationWorkerPool: AffinityThreadPool

    @usableFromInline
    internal let instrumentation: _InternalActorTransportInstrumentation

    internal init(settings: SerializationPoolSettings, serialization: Serialization, instrumentation: _InternalActorTransportInstrumentation? = nil) throws {
        self.serialization = serialization
        self.instrumentation = instrumentation ?? Noop_InternalActorTransportInstrumentation()
        var workerMapping: [String: Int] = [:]
        for (index, groupTags) in settings.serializationGroups.enumerated() {
            for groupTag in groupTags {
                // mapping from each actor path to the corresponding group index,
                // which maps 1:1 to the serialization worker number
                workerMapping[groupTag.value] = index
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
        recipient: ActorAddress,
        promise: EventLoopPromise<Serialization.Serialized>
    ) {
        // TODO: also record thr delay between submitting and starting serialization work here?
        self.enqueue(recipient: recipient, promise: promise, workerPool: self.serializationWorkerPool) {
            do {
                self.instrumentation.remoteActorMessageSerializeStart(id: promise.futureResult, recipient: recipient, message: message)
                let serialized = try self.serialization.serialize(message)

                traceLog_Serialization("serialize(\(message), to: \(recipient))")

                // TODO: collapse those two and only use the instrumentation points, also for metrics
                self.instrumentation.remoteActorMessageSerializeEnd(id: promise.futureResult, bytes: serialized.buffer.count)
                self.serialization.metrics.recordSerializationMessageOutbound(recipient, serialized.buffer.count)
                traceLog_Serialization("OK serialize(\(message), to: \(recipient))")

                return serialized
            } catch {
                self.instrumentation.remoteActorMessageSerializeEnd(id: promise.futureResult, bytes: 0)
                throw error
            }
        }
    }

    /// Note: The `Message` type MAY be `Never` in which case it is assumed that the message was intended for an already dead actor and the deserialized message is returned as such.
    @inlinable
    internal func deserializeAny(
        from buffer: Serialization.Buffer,
        using manifest: Serialization.Manifest,
        recipient: ActorAddress,
        // The only reason we use a wrapper instead of raw function is that (...) -> () do not have identity,
        // and we use identity of the callback to interact with the instrumentation for start/stop correlation.
        callback: DeserializationCallback
    ) {
        self.enqueue(recipient: recipient, onComplete: { callback.call($0) }, workerPool: self.deserializationWorkerPool) {
            do {
                self.serialization.metrics.recordSerializationMessageInbound(recipient, buffer.count)
                self.instrumentation.remoteActorMessageDeserializeStart(id: callback, recipient: recipient, bytes: buffer.count)

                // do the work, this may be "heavy"
                let deserialized = try self.serialization.deserializeAny(from: buffer, using: manifest)
                self.instrumentation.remoteActorMessageDeserializeEnd(id: callback, message: deserialized)
                return .message(deserialized)
            } catch {
                self.instrumentation.remoteActorMessageDeserializeEnd(id: callback, message: nil)
                throw error
            }
        }
    }

    @inline(__always)
    @usableFromInline
    internal func enqueue<Message>(
        recipient: ActorAddress,
        promise: EventLoopPromise<Message>,
        workerPool: AffinityThreadPool,
        task: @escaping () throws -> Message
    ) {
        self.enqueue(recipient: recipient, onComplete: promise.completeWith, workerPool: workerPool, task: { try task() })
    }

    @inline(__always)
    @usableFromInline
    internal func enqueue<Message>(
        recipient: ActorAddress,
        onComplete: @escaping (Result<Message, Error>) -> Void,
        workerPool: AffinityThreadPool,
        task: @escaping () throws -> Message
    ) {
        // TODO: also record thr delay between submitting and starting serialization work here?
        do {
            // check if messages for this particular actor should be handled
            // on a separate thread and submit to the worker pool
            if let path = recipient.tags[ActorTags.serializationGroup],
               let workerNumber = self.workerMapping[path] {
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
final class DeserializationCallback {
    /// A message deserialization may either be successful or fail due to attempting to deliver at an already dead actor,
    /// if this happens, we do not *statically* have the right `Message`  to cast to and the only remaining thing for such
    /// message is to be delivered as a dead letter thus we can avoid the cast entirely.
    ///
    /// Note: resolving a dead actor yields `_ActorRef<Never>` thus we would _never_ be able to deliver the message to it,
    /// and have to special case the dead letter delivery.
    @usableFromInline
    enum DeserializedMessage {
        case message(Any)
        case deadLetter(Any)
    }

    @usableFromInline
    let call: (Result<DeserializedMessage, Error>) -> Void

    init(_ callback: @escaping (Result<DeserializedMessage, Error>) -> Void) {
        self.call = callback
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization.Settings

public struct SerializationPoolSettings {
    public let serializationGroups: [[MessageSerializationGroupTag]]

    internal static var `default`: SerializationPoolSettings {
        SerializationPoolSettings(serializationGroups: [])
    }
}
