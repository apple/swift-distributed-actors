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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import DistributedActorsTestKit
import NIO
import XCTest

final class EventStreamTests: ActorSystemXCTestCase {
    func test_eventStream_shouldPublishEventsToAllSubscribers() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: String.self)
        let p2 = self.testKit.spawnTestProbe(expecting: String.self)
        let p3 = self.testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try EventStream(system, name: "StringEventStream", of: String.self)

        eventStream.subscribe(p1.ref)
        eventStream.subscribe(p2.ref)
        eventStream.subscribe(p3.ref)

        eventStream.publish("test")

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")
    }

    func test_eventStream_shouldNotPublishEventsToActorsAfterTheyUnsubscribed() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: String.self)
        let p2 = self.testKit.spawnTestProbe(expecting: String.self)
        let p3 = self.testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try EventStream(system, name: "StringEventStream", of: String.self)

        eventStream.subscribe(p1.ref)
        eventStream.subscribe(p2.ref)
        eventStream.subscribe(p3.ref)

        eventStream.publish("test")

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")

        eventStream.unsubscribe(p1.ref)
        eventStream.unsubscribe(p2.ref)

        eventStream.publish("test2")

        try p3.expectMessage("test2")
        try p1.expectNoMessage(for: .milliseconds(100))
        try p2.expectNoMessage(for: .milliseconds(100))
    }

    func test_eventStream_shouldUnsubscribeActorsOnTermination() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: String.self)
        let p2 = self.testKit.spawnTestProbe(expecting: String.self)
        let p3 = self.testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try EventStream(system, name: "StringEventStream", of: String.self)

        eventStream.subscribe(p1.ref)
        eventStream.subscribe(p2.ref)
        eventStream.subscribe(p3.ref)

        eventStream.publish("test")

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")

        // we are sending a `.terminated` system message instead of stopping the probe here
        // because we still need to verify that we don't receive any more messages after that
        eventStream.ref._sendSystemMessage(.terminated(ref: p1.ref.asAddressable, existenceConfirmed: true, addressTerminated: false))
        eventStream.ref._sendSystemMessage(.terminated(ref: p2.ref.asAddressable, existenceConfirmed: true, addressTerminated: false))

        eventStream.publish("test2")

        try p3.expectMessage("test2")
        try p1.expectNoMessage(for: .milliseconds(100))
        try p2.expectNoMessage(for: .milliseconds(100))
    }

    func test_eventStream_asyncSequence() throws {
        let eventStream = try EventStream(system, name: "StringEventStream", of: String.self)

        try runAsyncAndBlock {
            let consumer = EventStreamConsumer(eventStream)
            let consumeTask = Task {
                try await consumer.consume(1)
            }

            Task {
                while !consumer.running.load() {
                    try await Task.sleep(nanoseconds: 3_000_000)
                }

                eventStream.publish("test")
            }

            try await consumeTask.value
        }
    }
}

private struct EventStreamConsumer<Event: ActorMessage> {
    let running: Atomic<Bool> = Atomic(value: false)
    let counter: Atomic<Int> = Atomic(value: 0)

    private let events: EventStream<Event>
    private let eventHandler: (Event) throws -> Void

    init(_ events: EventStream<Event>, _ eventHandler: @escaping (Event) throws -> Void = { _ in }) {
        self.events = events
        self.eventHandler = eventHandler
    }

    func consume(_ n: Int) async throws {
        let iterator = self.events.makeAsyncIterator()

        while !iterator.ready {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        guard self.running.compareAndExchange(expected: false, desired: true) else { return }

        while let event = await iterator.next() {
            _ = self.counter.add(1)
            try self.eventHandler(event)

            if self.counter.load() >= n {
                break
            }
        }

        _ = self.running.compareAndExchange(expected: true, desired: false)
    }
}
