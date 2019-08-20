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
@testable import DistributedActors
import DistributedActorsTestKit

class ActorSubReceiveTests: XCTestCase {

    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    func test_subReceive_shouldBeAbleToReceiveMessages() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { message in
                p.tell("subreceive:\(message)")
            }
            refProbe.tell(subRef)

            return .unhandled
        }

        _ = try system.spawn("test-parent", (behavior))

        let subRef = try refProbe.expectMessage()

        subRef.tell("test")
        try p.expectMessage("subreceive:test")
    }

    func test_subReceive_shouldBeAbleToModifyActorState() throws {
        let p = testKit.spawnTestProbe(expecting: Int.self)
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<IncrementAndGet>.self)

        struct GetState {
            let replyTo: ActorRef<Int>
        }

        struct IncrementAndGet {
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
        for _ in 1...10 {
            subRef.tell(IncrementAndGet(replyTo: p.ref))
            let state = try p.expectMessage()
            state.shouldEqual(previousState + 1)

            ref.tell(GetState(replyTo: p.ref))
            try p.expectMessage().shouldEqual(state)

            previousState = state
        }
    }

    func test_subReceive_shouldBeWatchable() throws {
        let p = testKit.spawnTestProbe(expecting: Never.self)
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<Never> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { message in
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
        let p = testKit.spawnTestProbe(expecting: Never.self)
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<String> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { message in
                // ignore
            }
            refProbe.tell(subRef)

            return .receiveMessage { _ in
                return .stop
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
        let refProbe = testKit.spawnTestProbe(expecting: ActorRef<String>.self)

        let behavior: Behavior<String> = .setup { context in
            let subRef = context.subReceive("test-sub", String.self) { message in
                try failureMode.fail()
            }
            refProbe.tell(subRef)

            return .unhandled
        }

        _ = try system.spawn("test", props: .addingSupervision(strategy: .restart(atMost: 5, within: .seconds(5))), behavior)

        let subRef = try refProbe.expectMessage()

        subRef.tell("test")

        _ = try refProbe.expectMessage() // this means the actor was restarted
    }

    func test_subReceive_shouldTriggerSupervisionOnError() throws {
        try shared_subReceive_shouldTriggerSupervisionOnFailure(failureMode: .throwing)
    }

    func test_subReceive_shouldTriggerSupervisionOnFault() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try shared_subReceive_shouldTriggerSupervisionOnFailure(failureMode: .faulting)
        #endif
    }
}
