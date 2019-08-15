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

import XCTest
import NIO
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class EventStreamTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem("\(type(of: self))")
        self.testKit = ActorTestKit(system)
    }

    func test_eventStream_shouldPublishEventsToAllSubscribers() throws {
        let p1 = testKit.spawnTestProbe(expecting: String.self)
        let p2 = testKit.spawnTestProbe(expecting: String.self)
        let p3 = testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try system.spawn(EventStream.behavior(String.self), name: "StringEventStream")

        eventStream.tell(.subscribe(p1.ref))
        eventStream.tell(.subscribe(p2.ref))
        eventStream.tell(.subscribe(p3.ref))

        eventStream.tell(.publish("test"))

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")
    }

    func test_eventStream_shouldNotPublishEventsToActorsAfterTheyUnsubscribed() throws {
        let p1 = testKit.spawnTestProbe(expecting: String.self)
        let p2 = testKit.spawnTestProbe(expecting: String.self)
        let p3 = testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try system.spawn(EventStream.behavior(String.self), name: "StringEventStream")

        eventStream.tell(.subscribe(p1.ref))
        eventStream.tell(.subscribe(p2.ref))
        eventStream.tell(.subscribe(p3.ref))

        eventStream.tell(.publish("test"))

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")

        eventStream.tell(.unsubscribe(p1.ref))
        eventStream.tell(.unsubscribe(p2.ref))

        eventStream.tell(.publish("test2"))

        try p3.expectMessage("test2")
        try p1.expectNoMessage(for: .milliseconds(100))
        try p2.expectNoMessage(for: .milliseconds(100))
    }

    func test_eventStream_shouldUnsubscribeActorsOnTermination() throws {
        let p1 = testKit.spawnTestProbe(expecting: String.self)
        let p2 = testKit.spawnTestProbe(expecting: String.self)
        let p3 = testKit.spawnTestProbe(expecting: String.self)

        let eventStream = try system.spawn(EventStream.behavior(String.self), name: "StringEventStream")

        eventStream.tell(.subscribe(p1.ref))
        eventStream.tell(.subscribe(p2.ref))
        eventStream.tell(.subscribe(p3.ref))

        eventStream.tell(.publish("test"))

        try p1.expectMessage("test")
        try p2.expectMessage("test")
        try p3.expectMessage("test")

        // we are sending a `.terminated` system message instead of stopping the probe here
        // because we still need to verify that we don't receive any more messages after that
        //
        // TODO: is there a less hacky way to do this?
        eventStream.sendSystemMessage(.terminated(ref: p1.ref.asAddressable(), existenceConfirmed: true, addressTerminated: false))
        eventStream.sendSystemMessage(.terminated(ref: p2.ref.asAddressable(), existenceConfirmed: true, addressTerminated: false))

        eventStream.tell(.publish("test2"))

        try p3.expectMessage("test2")
        try p1.expectNoMessage(for: .milliseconds(100))
        try p2.expectNoMessage(for: .milliseconds(100))
    }
}
