//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Logging

/// `ClusterEventStream` manages a set of subscribers and forwards every event published to it to
/// all its subscribers. An actor can subscribe/unsubscribe to the event stream via `AsyncSequence`
/// constructs. Subscribers will be watched and removed in case they terminate.
///
/// `ClusterEventStream` is only meant to be used locally and does not buffer or redeliver messages.
public struct ClusterEventStream: AsyncSequence {
    public typealias Element = Cluster.Event

    private let actor: ClusterEventStreamActor?

    internal init(_ system: ClusterSystem, customName: String? = nil) {
        var props = ClusterEventStreamActor.props
        if let customName = customName {
            props._knownActorName = customName
        }

        self.actor = _Props.$forSpawn.withValue(props) {
            ClusterEventStreamActor(actorSystem: system)
        }
    }

    // For testing only
    internal init() {
        self.actor = nil
    }

    func subscribe(_ ref: _ActorRef<Cluster.Event>, file: String = #filePath, line: UInt = #line) async {
        guard let actor = self.actor else { return }

        await actor.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            __secretlyKnownToBeLocal.subscribe(ref)
        }
    }

    func unsubscribe(_ ref: _ActorRef<Cluster.Event>, file: String = #filePath, line: UInt = #line) async {
        guard let actor = self.actor else { return }

        await actor.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            __secretlyKnownToBeLocal.unsubscribe(ref)
        }
    }

    private func subscribe(_ oid: ObjectIdentifier, eventHandler: @escaping (Cluster.Event) -> Void) async {
        guard let actor = self.actor else { return }

        await actor.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            __secretlyKnownToBeLocal.subscribe(oid, eventHandler: eventHandler)
        }
    }

    private func unsubscribe(_ oid: ObjectIdentifier) async {
        guard let actor = self.actor else { return }

        await actor.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            __secretlyKnownToBeLocal.unsubscribe(oid)
        }
    }

    func publish(_ event: Cluster.Event, file: String = #filePath, line: UInt = #line) async {
        guard let actor = self.actor else { return }

        await actor.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            __secretlyKnownToBeLocal.publish(event)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(self)
    }

    public class AsyncIterator: AsyncIteratorProtocol {
        var underlying: AsyncStream<Cluster.Event>.Iterator!

        init(_ eventStream: ClusterEventStream) {
            let id = ObjectIdentifier(self)
            self.underlying = AsyncStream<Cluster.Event> { continuation in
                Task {
                    await eventStream.subscribe(id) { event in
                        continuation.yield(event)
                    }
                }

                continuation.onTermination = { _ in
                    Task {
                        await eventStream.unsubscribe(id)
                    }
                }
            }.makeAsyncIterator()
        }

        public func next() async -> Cluster.Event? {
            await self.underlying.next()
        }
    }
}

// FIXME(distributed): the only reason this actor is distributed is because of LifecycleWatch
internal distributed actor ClusterEventStreamActor: LifecycleWatch {
    typealias ActorSystem = ClusterSystem

    static var props: _Props {
        var ps = _Props()
        ps._knownActorName = "clustEventStream"
        ps._systemActor = true
        ps._wellKnown = true
        return ps
    }

    // We maintain a snapshot i.e. the "latest version of the membership",
    // in order to eagerly publish it to anyone who subscribes immediately,
    // followed by joining them to the subsequent ``Cluster/Event`` publishes.
    //
    // Thanks to this, any subscriber immediately gets a pretty recent view of the membership,
    // followed by the usual updates via events. Since all events are published through this
    // event stream actor, all subscribers are guaranteed to see events in the right order,
    // and not miss any information as long as they apply all events they receive.
    private var snapshot = Cluster.Membership.empty

    private var subscribers: [ActorID: _ActorRef<Cluster.Event>] = [:]
    private var asyncSubscribers: [ObjectIdentifier: (Cluster.Event) -> Void] = [:]

    private lazy var log = Logger(actor: self)

    internal init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    func subscribe(_ ref: _ActorRef<Cluster.Event>) {
        self.subscribers[ref.id] = ref
        self.log.trace("Successfully subscribed [\(ref)], offering membership snapshot")
        ref.tell(.snapshot(self.snapshot))
    }

    func unsubscribe(_ ref: _ActorRef<Cluster.Event>) {
        if self.subscribers.removeValue(forKey: ref.id) != nil {
            self.log.trace("Successfully unsubscribed [\(ref)]")
        } else {
            self.log.warning("Received `.unsubscribe` for non-subscriber [\(ref)]")
        }
    }

    func subscribe(_ oid: ObjectIdentifier, eventHandler: @escaping (Cluster.Event) -> Void) {
        self.asyncSubscribers[oid] = eventHandler
        self.log.trace("Successfully added async subscriber [\(oid)], offering membership snapshot")
        eventHandler(.snapshot(self.snapshot))
    }

    func unsubscribe(_ oid: ObjectIdentifier) {
        if self.asyncSubscribers.removeValue(forKey: oid) != nil {
            self.log.trace("Successfully removed async subscriber [\(oid)]")
        } else {
            self.log.warning("Received async `.unsubscribe` for non-subscriber [\(oid)]")
        }
    }

    func publish(_ event: Cluster.Event) {
        do {
            try self.snapshot.apply(event: event)

            for subscriber in self.subscribers.values {
                subscriber.tell(event)
            }
            for subscriber in self.asyncSubscribers.values {
                subscriber(event)
            }

            self.log.trace(
                "Published event \(event) to \(self.subscribers.count) subscribers and \(self.asyncSubscribers.count) async subscribers",
                metadata: [
                    "eventStream/event": "\(reflecting: event)",
                    "eventStream/subscribers": Logger.MetadataValue.array(self.subscribers.map {
                        Logger.MetadataValue.stringConvertible($0.key)
                    }),
                    "eventStream/asyncSubscribers": Logger.MetadataValue.array(self.asyncSubscribers.map {
                        Logger.MetadataValue.stringConvertible("\($0.key)")
                    }),
                ]
            )
        } catch {
            self.log.error("Failed to apply [\(event)], error: \(error)")
        }
    }

    distributed func terminated(actor id: ActorID) {
        if self.subscribers.removeValue(forKey: id) != nil {
            self.log.trace("Removed subscriber [\(id)], because it terminated")
        }
    }
}
