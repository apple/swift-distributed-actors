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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class ActorRefAdapterTests: XCTestCase {

    let system = ActorSystem("ActorRefAdapterTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
    }

    func test_adaptedRef_shouldConvertMessages() throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<Int>.self)

        let behavior: Behavior<String> = .setup { context in
            refProbe.tell(context.messageAdapter { "\($0)" })
            return .receiveMessage { msg in
                probe.ref.tell(msg)
                return .same
            }
        }

        _ = try! system.spawnAnonymous(behavior)

        let adapted = try refProbe.expectMessage()

        for i in 0...10 {
            adapted.tell(i)
        }

        for i in 0...10 {
            try probe.expectMessage("\(i)")
        }
    }

    func test_adaptedRef_overNetwork_shouldConvertMessages() throws {
        let systemOne = ActorSystem("One-RemoteActorRefAdapterTests") { settings in
            settings.cluster.enabled = true
            settings.cluster.bindAddress.host = "127.0.0.1"
            settings.cluster.bindAddress.port = 1881
        }
        defer { systemOne.shutdown() }
        let firstTestKit = ActorTestKit(systemOne)
        let probe = firstTestKit.spawnTestProbe(expecting: String.self)
        let refProbe = firstTestKit.spawnTestProbe(expecting: ActorRef<Int>.self)

        let systemTwo = ActorSystem("Two-RemoteActorRefAdapterTests") { settings in 
            settings.cluster.enabled = true
            settings.cluster.bindAddress.host = "127.0.0.1"
            settings.cluster.bindAddress.port = 1991
        }
        defer { systemTwo.shutdown() }

        systemOne.clusterShell.tell(.command(.handshakeWith(systemTwo.settings.cluster.bindAddress))) // TODO nicer API

        sleep(2)

        let behavior: Behavior<String> = .setup { context in
            refProbe.tell(context.messageAdapter { "\($0)" })
            return .receiveMessage { msg in
                probe.ref.tell(msg)
                return .same
            }
        }

        _ = try! systemTwo.spawn(behavior, name: "target")

        let adapted: ActorRef<Int> = try refProbe.expectMessage()

        for i in 0...10 {
            adapted.tell(i)
        }

        for i in 0...10 {
            try probe.expectMessage("\(i)")
        }
    }

    func test_adaptedRef_shouldBeWatchable() throws {
        let probe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Int> = .setup { context in
            probe.tell(context.messageAdapter { _ in 0 })
            return .receiveMessage { _ in
                return .stopped
            }
        }

        _ = try system.spawnAnonymous(behavior)

        let adaptedRef = try probe.expectMessage()

        probe.watch(adaptedRef)

        adaptedRef.tell("test")

        try probe.expectTerminated(adaptedRef)
    }

    enum LifecycleTestMessage {
        case createAdapter(replyTo: ActorRef<ActorRef<String>>)
        case crash
        case stop
        case message(String)
    }

    func test_adaptedRef_shouldShareTheSameLifecycleAsItsActor() throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)
        let receiveRefProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let strategy = SupervisionStrategy.restart(atMost: 5, within: .seconds(5))

        let behavior: Behavior<LifecycleTestMessage> = .setup { context in
            return .receiveMessage {
                switch $0 {
                case .crash:
                    throw Boom()
                case .createAdapter(let replyTo):
                    replyTo.tell(context.messageAdapter { .message("\($0)") })
                    return .same
                case .stop:
                    return .stopped
                case .message(let string):
                    probe.tell("received:\(string)")
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: .addingSupervision(strategy: strategy))

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef = try receiveRefProbe.expectMessage()

        probe.watch(ref)
        probe.watch(adaptedRef)

        ref.tell(.crash)

        try probe.expectNoTerminationSignal(for: .milliseconds(100))

        adaptedRef.tell("test")
        try probe.expectMessage("received:test")

        ref.tell(.stop)
        try probe.expectTerminatedInAnyOrder([ref.asAddressable(), adaptedRef.asAddressable()])
    }

    func test_adaptedRef_newAdapterShouldReplaceOld() throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)
        let receiveRefProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let strategy = SupervisionStrategy.restart(atMost: 5, within: .seconds(5))

        let behavior: Behavior<LifecycleTestMessage> = .setup { context in
            var adapterCounter = 0
            return .receiveMessage {
                switch $0 {
                case .createAdapter(let replyTo):
                    let counter = adapterCounter
                    replyTo.tell(context.messageAdapter { .message("adapter-\(counter):\($0)") })
                    adapterCounter += 1
                    return .same
                case .message(let string):
                    probe.tell("received:\(string)")
                    return .same
                default:
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: .addingSupervision(strategy: strategy))

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef = try receiveRefProbe.expectMessage()

        adaptedRef.tell("test")
        try probe.expectMessage("received:adapter-0:test")

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef2 = try receiveRefProbe.expectMessage()

        adaptedRef2.tell("test")
        try probe.expectMessage("received:adapter-1:test")

        // existing ref stays valid
        adaptedRef.tell("test")
        try probe.expectMessage("received:adapter-0:test")
    }

}
