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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

class ActorRefAdapterTests: ActorSystemTestBase {
    func test_adaptedRef_shouldConvertMessages() throws {
        let probe = self.testKit.spawnTestProbe(expecting: String.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<Int>.self)

        let behavior: Behavior<String> = .setup { context in
            refProbe.tell(context.messageAdapter { "\($0)" })
            return .receiveMessage { msg in
                probe.ref.tell(msg)
                return .same
            }
        }

        _ = try! self.system.spawn(.anonymous, behavior)

        let adapted = try refProbe.expectMessage()

        for i in 0 ... 10 {
            adapted.tell(i)
        }

        for i in 0 ... 10 {
            try probe.expectMessage("\(i)")
        }
    }

    func test_adaptedRef_overNetwork_shouldConvertMessages() throws {
        let firstSystem = self.setUpNode("One-RemoteActorRefAdapterTests") { settings in
            settings.cluster.enabled = true
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 1881
        }
        let firstTestKit = self.testKit(firstSystem)
        let probe = firstTestKit.spawnTestProbe(expecting: String.self)
        let refProbe = firstTestKit.spawnTestProbe(expecting: ActorRef<Int>.self)

        let systemTwo = self.setUpNode("Two-RemoteActorRefAdapterTests") { settings in
            settings.cluster.enabled = true
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 1991
        }

        firstSystem.cluster.join(node: systemTwo.settings.cluster.node)

        sleep(2)

        let behavior: Behavior<String> = .setup { context in
            refProbe.tell(context.messageAdapter { "\($0)" })
            return .receiveMessage { msg in
                probe.ref.tell(msg)
                return .same
            }
        }

        _ = try! systemTwo.spawn("target", behavior)

        let adapted: ActorRef<Int> = try refProbe.expectMessage()

        for i in 0 ... 10 {
            adapted.tell(i)
        }

        for i in 0 ... 10 {
            try probe.expectMessage("\(i)")
        }
    }

    func test_adaptedRef_shouldBeWatchable() throws {
        let probe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Int> = .setup { context in
            probe.tell(context.messageAdapter { _ in 0 })
            return .receiveMessage { _ in
                .stop
            }
        }

        _ = try system.spawn(.anonymous, behavior)

        let adaptedRef = try probe.expectMessage()

        probe.watch(adaptedRef)

        adaptedRef.tell("test")

        try probe.expectTerminated(adaptedRef)
    }

    func test_adapter_shouldAllowDroppingMessages() throws {
        let probe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let pAdapted = self.testKit.spawnTestProbe(expecting: Int.self)

        let behavior: Behavior<Int> = .setup { context in
            probe.tell(context.messageAdapter { message in
                if message.contains("drop") {
                    return nil
                } else {
                    return message.count
                }
            })
            return .receiveMessage { stringLength in
                pAdapted.tell(stringLength)
                return .same
            }
        }

        _ = try system.spawn(.anonymous, behavior)

        let adaptedRef = try probe.expectMessage()

        probe.watch(adaptedRef)

        adaptedRef.tell("hi")
        adaptedRef.tell("drop")
        adaptedRef.tell("hello")
        adaptedRef.tell("drop-hello")

        try pAdapted.expectMessage("hi".count)
        try pAdapted.expectMessage("hello".count)
        try pAdapted.expectNoMessage(for: .milliseconds(10))
    }

    enum LifecycleTestMessage: NonTransportableActorMessage {
        case createAdapter(replyTo: ActorRef<ActorRef<String>>)
        case crash
        case stop
        case message(String)
    }

    func test_adaptedRef_shouldShareTheSameLifecycleAsItsActor() throws {
        let probe = self.testKit.spawnTestProbe(expecting: String.self)
        let receiveRefProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let strategy = SupervisionStrategy.restart(atMost: 5, within: .seconds(5))

        let behavior: Behavior<LifecycleTestMessage> = .setup { context in
            .receiveMessage {
                switch $0 {
                case .crash:
                    throw Boom()
                case .createAdapter(let replyTo):
                    replyTo.tell(context.messageAdapter { .message("\($0)") })
                    return .same
                case .stop:
                    return .stop
                case .message(let string):
                    probe.tell("received:\(string)")
                    return .same
                }
            }
        }

        let ref = try system.spawn(.anonymous, props: .supervision(strategy: strategy), behavior)

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
        let probe = self.testKit.spawnTestProbe(expecting: String.self)
        let receiveRefProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

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

        let ref = try system.spawn(.anonymous, props: .supervision(strategy: strategy), behavior)

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef = try receiveRefProbe.expectMessage()

        adaptedRef.tell("test")
        try probe.expectMessage("received:adapter-0:test")

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef2 = try receiveRefProbe.expectMessage()

        adaptedRef2.tell("test")
        try probe.expectMessage("received:adapter-1:test")

        // existing ref stays valid, but uses new adapter
        adaptedRef.tell("test")
        try probe.expectMessage("received:adapter-1:test")
    }

    func test_adaptedRef_shouldDeadLetter_whenOwnerTerminated() throws {
        let logCaptureHandler = LogCapture()
        let system = ActorSystem("\(type(of: self))-2") { settings in
            settings.logging.overrideLoggerFactory = logCaptureHandler.loggerFactory(captureLabel: settings.cluster.node.systemName)
        }
        defer { system.shutdown().wait() }

        let probe = self.testKit.spawnTestProbe(expecting: String.self)
        let receiveRefProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<LifecycleTestMessage> = .setup { context in
            .receiveMessage {
                switch $0 {
                case .createAdapter(let replyTo):
                    replyTo.tell(context.messageAdapter { .message("adapter:\($0)") })
                    return .stop
                default:
                    return .stop
                }
            }
        }

        let ref = try system.spawn(.anonymous, behavior)
        probe.watch(ref)

        ref.tell(.createAdapter(replyTo: receiveRefProbe.ref))
        let adaptedRef = try receiveRefProbe.expectMessage()

        // the owner has terminated
        try probe.expectTerminated(ref)

        // thus sending to the adapter results in a dead letter
        adaptedRef.tell("whoops")
        let expectedLine = #line - 1
        let expectedFile = #file

        try logCaptureHandler.shouldContain(
            message: "*was not delivered to [*", at: .info,
            expectedFile: expectedFile, expectedLine: expectedLine
        )
    }

    func test_adaptedRef_useSpecificEnoughAdapterMostRecentlySet() throws {
        class TopExample: NonTransportableActorMessage {}
        class BottomExample: TopExample {}

        let probe = self.testKit.spawnTestProbe(expecting: String.self)

        let probeTop = self.testKit.spawnTestProbe(expecting: ActorRef<TopExample>.self)
        let probeBottom = self.testKit.spawnTestProbe(expecting: ActorRef<BottomExample>.self)

        let behavior: Behavior<LifecycleTestMessage> = .setup { context in
            let topRef: ActorRef<TopExample> = context.messageAdapter { .message("adapter-top:\($0)") }
            probeTop.tell(topRef)
            let bottomRef: ActorRef<BottomExample> = context.messageAdapter { .message("adapter-bottom:\($0)") }
            probeBottom.tell(bottomRef)

            return .receiveMessage {
                switch $0 {
                case .message(let string):
                    probe.tell("received:\(string)")
                    return .same
                default:
                    return .same
                }
            }
        }

        _ = try system.spawn(.anonymous, behavior)

        let topRef: ActorRef<TopExample> = try probeTop.expectMessage()
        let bottomRef: ActorRef<BottomExample> = try probeBottom.expectMessage()

        let top = TopExample()
        let bottom = BottomExample()

        topRef.tell(top)
        try probe.expectMessage("received:adapter-top:\(top)")

        bottomRef.tell(bottom)
        try probe.expectMessage("received:adapter-bottom:\(bottom)")

        topRef.tell(bottom)
        try probe.expectMessage("received:adapter-bottom:\(bottom)")
    }
}
