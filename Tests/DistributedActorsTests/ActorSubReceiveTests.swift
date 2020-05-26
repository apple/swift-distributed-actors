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

final class ActorSubReceiveTests: ActorSystemTestBase {
    func test_subReceive_shouldBeAbleToReceiveMessages() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { message in
                p.tell("subreceive:\(message)")
            }
            refProbe.tell(subRef)

            return .receiveMessage { _ in .same }
        }

        _ = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        subRef.tell("test")
        try p.expectMessage("subreceive:test")
    }

    struct TestSubReceiveType<Value>: Codable {}
    func test_subReceive_notCrashWhenTypeIncludesSpecialChar() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<TestSubReceiveType<Void>>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive("test-sub", TestSubReceiveType<Void>.self) { message in
                p.tell("subreceive:\(message)")
            }
            _ = context.subReceive("test-sub", TestSubReceiveType<String?>.self) { message in
                p.tell("subreceive:\(message)")
            }
            refProbe.tell(subRef)

            return .receiveMessage { _ in .same }
        }

        _ = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        subRef.tell(TestSubReceiveType<Void>())
        try p.expectMessage("subreceive:\(TestSubReceiveType<Void>())")
    }

    func test_subReceiveId_fromGenericType_shouldNotBlowUp() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<Set<String>>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive(Set<String>.self) { message in
                p.tell("subreceive:\(message.count)")
            }
            refProbe.tell(subRef)

            return .receiveMessage { _ in .same }
        }

        _ = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        subRef.tell(Set(["one", "two"]))
        try p.expectMessage("subreceive:2")
    }

    func test_subReceive_shouldBeAbleToModifyActorState() throws {
        let p = self.testKit.spawnTestProbe(expecting: Int.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<IncrementAndGet>.self)

        struct GetState: ActorMessage {
            let replyTo: ActorRef<Int>
        }

        struct IncrementAndGet: ActorMessage {
            let replyTo: ActorRef<Int>
        }

        let behavior: Behavior<GetState> = .setup { context in
            var state: Int = 0

            let subRef = context.subReceive("test-sub", IncrementAndGet.self) { message in
                state += 1
                message.replyTo.tell(state)
            }
            refProbe.tell(subRef)

            return .receiveMessage { message in
                message.replyTo.tell(state)
                return .same
            }
        }

        let ref = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        var previousState = 0
        for _ in 1 ... 10 {
            subRef.tell(IncrementAndGet(replyTo: p.ref))
            let state = try p.expectMessage()
            state.shouldEqual(previousState + 1)

            ref.tell(GetState(replyTo: p.ref))
            try p.expectMessage().shouldEqual(state)

            previousState = state
        }
    }

    func test_subReceive_shouldBeWatchable() throws {
        let p = self.testKit.spawnTestProbe(expecting: Never.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { _ in
                throw Boom()
            }
            refProbe.tell(subRef)

            return .unhandled
        }

        _ = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        p.watch(subRef)

        subRef.tell("test")
        try p.expectTerminated(subRef)
    }

    func test_subReceive_shouldShareLifetimeWithParent() throws {
        let p = self.testKit.spawnTestProbe(expecting: Never.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<String> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { _ in
                // ignore
            }
            refProbe.tell(subRef)

            return .receiveMessage { _ in
                .stop
            }
        }

        let ref = try system.spawn("test-parent", behavior)

        let subRef = try refProbe.expectMessage()

        p.watch(ref)
        p.watch(subRef)

        ref.tell("test")

        try p.expectTerminatedInAnyOrder([ref.asAddressable(), subRef.asAddressable()])
    }

    func shared_subReceive_shouldTriggerSupervisionOnFailure(failureMode: SupervisionTests.FailureMode) throws {
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<String> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { _ in
                try failureMode.fail()
            }
            refProbe.tell(subRef)

            return .unhandled
        }

        _ = try system.spawn("test", props: .supervision(strategy: .restart(atMost: 5, within: .seconds(5))), behavior)

        let subRef = try refProbe.expectMessage()

        subRef.tell("test")

        _ = try refProbe.expectMessage() // this means the actor was restarted
    }

    func test_subReceive_shouldTriggerSupervisionOnError() throws {
        try self.shared_subReceive_shouldTriggerSupervisionOnFailure(failureMode: .throwing)
    }

    func test_subReceive_shouldBeReplacedIfRegisteredAgainUnderSameKey() throws {
        struct TestMessage: ActorMessage {
            let replyTo: ActorRef<String>
            let message: String
        }

        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let refProbe = self.testKit.spawnTestProbe(expecting: ActorRef<TestMessage>.self)

        let behavior: Behavior<String> = .setup { context in
            var subReceiveCounter = 0
            return .receiveMessage { message in
                if message == "install" {
                    let count = subReceiveCounter
                    subReceiveCounter += 1
                    let subRef = context.subReceive("test-sub", TestMessage.self) { message in
                        message.replyTo.tell("subReceive-\(count):\(message.message)")
                    }
                    refProbe.tell(subRef)
                }

                return .same
            }
        }

        let ref = try system.spawn("test", behavior)

        ref.tell("install")
        let subRef = try refProbe.expectMessage()

        subRef.tell(TestMessage(replyTo: p.ref, message: "test"))
        try p.expectMessage("subReceive-0:test")

        ref.tell("install")
        let subRef2 = try refProbe.expectMessage()

        subRef.tell(TestMessage(replyTo: p.ref, message: "test"))
        try p.expectMessage("subReceive-1:test") // subReceive has been replaced, so we should get an incremented count

        subRef2.tell(TestMessage(replyTo: p.ref, message: "test"))
        try p.expectMessage("subReceive-1:test") // second sub ref should also work
    }
}
