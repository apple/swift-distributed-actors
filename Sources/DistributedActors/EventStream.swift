//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// `EventStream` manages a set of subscribers and forwards any events sent to it via the `.publish`
/// message to all subscribers. An actor can subscribe to the events by sending a `.subscribe` message
/// and unsubscribe by sending `.unsubscribe`. Subscribers will be watched and un-subscribes in case
/// they terminate.
///
/// `EventStream` is only meant to be used locally and does not buffer or redeliver messages.
public struct EventStream<Event: ActorMessage>: AsyncSequence {
    public typealias Element = Event

    internal let ref: ActorRef<EventStreamShell.Message<Event>>

    private var events: AsyncStream<Event>!
    private var eventContinuation: AsyncStream<Event>.Continuation!

    public init(_ system: ActorSystem, name: String, of type: Event.Type = Event.self) throws {
        try self.init(system, name: name, of: type, systemStream: false)
    }

    internal init(
        _ system: ActorSystem,
        name: String,
        of type: Event.Type = Event.self,
        systemStream: Bool,
        customBehavior: Behavior<EventStreamShell.Message<Event>>? = nil
    ) throws {
        let behavior: Behavior<EventStreamShell.Message<Event>> = customBehavior ?? EventStreamShell.behavior(type)
        if systemStream {
            self.init(ref: try system._spawnSystemActor(.unique(name), behavior))
        } else {
            self.init(ref: try system.spawn(.unique(name), behavior))
        }
    }

    internal init(ref: ActorRef<EventStreamShell.Message<Event>>) {
        self.ref = ref
        self.events = AsyncStream<Event> { continuation in
            self.eventContinuation = continuation
        }
    }

    public func subscribe(_ ref: ActorRef<Event>, file: String = #file, line: UInt = #line) {
        self.ref.tell(.subscribe(ref), file: file, line: line)
    }

    public func unsubscribe(_ ref: ActorRef<Event>, file: String = #file, line: UInt = #line) {
        self.ref.tell(.unsubscribe(ref), file: file, line: line)
    }

    public func publish(_ event: Event, file: String = #file, line: UInt = #line) {
        self.ref.tell(.publish(event), file: file, line: line)
        self.eventContinuation.yield(event)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(underlying: self.events.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var underlying: AsyncStream<Event>.Iterator

        public mutating func next() async -> Event? {
            await self.underlying.next()
        }
    }
}

internal enum EventStreamShell {
    enum Message<Event: ActorMessage>: NonTransportableActorMessage { // TODO: make it codable, transportability depends on the Event really
        /// Subscribe to receive events
        case subscribe(ActorRef<Event>)
        /// Unsubscribe from receiving events
        case unsubscribe(ActorRef<Event>)
        /// Publish an event to all subscribers
        case publish(Event)
    }

    static func behavior<Event>(_: Event.Type) -> Behavior<Message<Event>> {
        .setup { context in
            var subscribers: [ActorAddress: ActorRef<Event>] = [:]

            let behavior: Behavior<Message<Event>> = .receiveMessage { message in
                switch message {
                case .subscribe(let ref):
                    subscribers[ref.address] = ref
                    context.watch(ref)
                    context.log.trace("Successfully subscribed [\(ref)]")

                case .unsubscribe(let ref):
                    if subscribers.removeValue(forKey: ref.address) != nil {
                        context.unwatch(ref)
                        context.log.trace("Successfully unsubscribed [\(ref)]")
                    } else {
                        context.log.warning("Received `.unsubscribe` for non-subscriber [\(ref)]")
                    }

                case .publish(let event):
                    for subscriber in subscribers.values {
                        subscriber.tell(event)
                    }
                    context.log.trace("Published event \(event) to \(subscribers.count) subscribers")
                }

                return .same
            }

            return behavior.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                if subscribers.removeValue(forKey: signal.address) != nil {
                    context.log.trace("Removed subscriber [\(signal.address)], because it terminated")
                } else {
                    context.log.warning("Received unexpected termination signal for non-subscriber [\(signal.address)]")
                }

                return .same
            }
        }
    }
}
