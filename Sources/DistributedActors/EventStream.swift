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

import Atomics

/// `EventStream` manages a set of subscribers and forwards any events sent to it via the `.publish`
/// message to all subscribers. An actor can subscribe to the events by sending a `.subscribe` message
/// and unsubscribe by sending `.unsubscribe`. Subscribers will be watched and un-subscribes in case
/// they terminate.
///
/// `EventStream` is only meant to be used locally and does not buffer or redeliver messages.
public struct EventStream<Event: ActorMessage>: AsyncSequence {
    public typealias Element = Event

    internal let ref: _ActorRef<EventStreamShell.Message<Event>>

    public init(_ system: ClusterSystem, name: String, of type: Event.Type = Event.self) throws {
        try self.init(system, name: name, of: type, systemStream: false)
    }

    internal init(
        _ system: ClusterSystem,
        name: String,
        of type: Event.Type = Event.self,
        systemStream: Bool,
        customBehavior: _Behavior<EventStreamShell.Message<Event>>? = nil
    ) throws {
        let behavior: _Behavior<EventStreamShell.Message<Event>> = customBehavior ?? EventStreamShell.behavior(type)
        if systemStream {
            self.init(ref: try system._spawnSystemActor(.unique(name), behavior))
        } else {
            self.init(ref: try system._spawn(.unique(name), behavior))
        }
    }

    internal init(ref: _ActorRef<EventStreamShell.Message<Event>>) {
        self.ref = ref
    }

    public func subscribe(_ ref: _ActorRef<Event>, file: String = #file, line: UInt = #line) {
        self.ref.tell(.subscribe(ref), file: file, line: line)
    }

    public func unsubscribe(_ ref: _ActorRef<Event>, file: String = #file, line: UInt = #line) {
        self.ref.tell(.unsubscribe(ref), file: file, line: line)
    }

    public func publish(_ event: Event, file: String = #file, line: UInt = #line) {
        self.ref.tell(.publish(event), file: file, line: line)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(ref: self.ref)
    }

    public class AsyncIterator: AsyncIteratorProtocol {
        var underlying: AsyncStream<Event>.Iterator!

        private let subscribed: ManagedAtomic<Bool> = .init(false)

        // TODO: clean this up since it's used by tests only (e.g., EventStreamConsumer)
        var ready: Bool {
            self.subscribed.load(ordering: .relaxed)
        }

        init(ref: _ActorRef<EventStreamShell.Message<Event>>) {
            let id = ObjectIdentifier(self)
            self.underlying = AsyncStream<Event> { continuation in
                ref.tell(.asyncSubscribe(id, { event in continuation.yield(event) }) {
                    _ = self.subscribed.compareExchange(expected: false, desired: true, ordering: .relaxed)
                })

                continuation.onTermination = { @Sendable (_) in
                    ref.tell(.asyncUnsubscribe(id) {
                        _ = self.subscribed.compareExchange(expected: true, desired: false, ordering: .relaxed)
                    })
                }
            }.makeAsyncIterator()
        }

        deinit {
//            self.subscribed.destroy()
        }

        public func next() async -> Event? {
            await self.underlying.next()
        }
    }
}

internal enum EventStreamShell {
    enum Message<Event: ActorMessage>: NonTransportableActorMessage { // TODO: make it codable, transportability depends on the Event really
        /// Subscribe to receive events
        case subscribe(_ActorRef<Event>)
        /// Unsubscribe from receiving events
        case unsubscribe(_ActorRef<Event>)
        /// Publish an event to all subscribers
        case publish(Event)

        /// Add async subscriber to the event stream
        case asyncSubscribe(ObjectIdentifier, (Event) -> Void, continue: () -> Void)
        /// Remove async subscriber
        case asyncUnsubscribe(ObjectIdentifier, continue: () -> Void)
    }

    static func behavior<Event>(_: Event.Type) -> _Behavior<Message<Event>> {
        .setup { context in
            var subscribers: [ActorID: _ActorRef<Event>] = [:]
            var asyncSubscribers: [ObjectIdentifier: (Event) -> Void] = [:]

            let behavior: _Behavior<Message<Event>> = .receiveMessage { message in
                switch message {
                case .subscribe(let ref):
                    subscribers[ref.id] = ref
                    context.watch(ref)
                    context.log.trace("Successfully subscribed [\(ref)]")

                case .unsubscribe(let ref):
                    if subscribers.removeValue(forKey: ref.id) != nil {
                        context.unwatch(ref)
                        context.log.trace("Successfully unsubscribed [\(ref)]")
                    } else {
                        context.log.warning("Received `.unsubscribe` for non-subscriber [\(ref)]")
                    }

                case .publish(let event):
                    for subscriber in subscribers.values {
                        subscriber.tell(event)
                    }
                    for subscriber in asyncSubscribers.values {
                        subscriber(event)
                    }
                    context.log.trace("Published event \(event) to \(subscribers.count) subscribers and \(asyncSubscribers.count) async subscribers")

                case .asyncSubscribe(let id, let eventHandler, let `continue`):
                    asyncSubscribers[id] = eventHandler
                    context.log.trace("Successfully added async subscriber [\(id)]")
                    `continue`()

                case .asyncUnsubscribe(let id, let `continue`):
                    if asyncSubscribers.removeValue(forKey: id) != nil {
                        context.log.trace("Successfully removed async subscriber [\(id)]")
                    } else {
                        context.log.warning("Received `.asyncUnsubscribe` for non-subscriber [\(id)]")
                    }
                    `continue`()
                }

                return .same
            }

            return behavior.receiveSpecificSignal(_Signals.Terminated.self) { context, signal in
                if subscribers.removeValue(forKey: signal.id) != nil {
                    context.log.trace("Removed subscriber [\(signal.id)], because it terminated")
                } else {
                    context.log.warning("Received unexpected termination signal for non-subscriber [\(signal.id)]")
                }

                return .same
            }
        }
    }
}
