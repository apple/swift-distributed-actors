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

class ActorLifecycleTests: ActorSystemTestBase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: starting actors

    func test_spawn_shouldNotAllowStartingWith_Same() throws {
        // since there is no previous behavior to stay "same" name at the same time:

        let ex = shouldThrow {
            let sameBehavior: Behavior<String> = .same
            _ = try self.system.spawn("same", sameBehavior)
        }

        "\(ex)".shouldEqual("""
        notAllowedAsInitial(DistributedActors.Behavior<Swift.String>.same)
        """)
    }

    func test_spawn_shouldNotAllowStartingWith_Unhandled() throws {
        // the purpose of unhandled is to combine with things that can handle, and if we start a raw unhandled
        // it always will be unhandled until we use some signal to make it otherwise... weird edge case which
        // is better avoided all together.
        //
        // We do allow starting with .ignore though since that's like a "blackhole"

        let ex = shouldThrow {
            let unhandledBehavior: Behavior<String> = .unhandled
            _ = try system.spawn("unhandled", unhandledBehavior)
        }

        "\(ex)".shouldEqual("notAllowedAsInitial(DistributedActors.Behavior<Swift.String>.unhandled)")
    }

    func test_spawn_shouldNotAllowIllegalActorNames() throws {
        func check(illegalName: String, expectedError: String) throws {
            let err = shouldThrow {
                let b: Behavior<String> = .ignore

                // more coverage for all the different chars in [[ActorPathTests]]
                _ = try system.spawn(.unique(illegalName), b)
            }
            "\(err)".shouldEqual(expectedError)
        }

        try check(
            illegalName: "hello world",
            expectedError: """
            illegalActorPathElement(name: "hello world", illegal: " ", index: 5)
            """
        )

        try check(
            illegalName: "he//o",
            expectedError: """
            illegalActorPathElement(name: "he//o", illegal: "/", index: 2)
            """
        )
        try check(
            illegalName: "ążŻŌżąć",
            expectedError: """
            illegalActorPathElement(name: "ążŻŌżąć", illegal: "ą", index: 0)
            """
        )
        try check(
            illegalName: "カピバラ",
            expectedError: """
            illegalActorPathElement(name: "カピバラ", illegal: "カ", index: 0)
            """
        ) // ka-pi-ba-ra
    }

    func test_spawn_shouldThrowFromMultipleActorsWithTheSamePathBeingSpawned() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let spawner: Behavior<String> = .receive { context, name in
            let fromName = context.path
            let _: ActorRef<Never> = try context.system.spawn(
                "\(name)",
                .setup { context in
                    p.tell("me:\(context.path) spawned from \(fromName)")
                    return .receiveMessage { _ in .stop } // keep ignoring
                }
            )
            return .stop
        }
        try system.spawn("a", spawner).tell("charlie")
        try self.system.spawn("b", spawner).tell("charlie")
        try self.system.spawn("c", spawner).tell("charlie")
        try self.system.spawn("d", spawner).tell("charlie")
        try self.system.spawn("e", spawner).tell("charlie")
        try self.system.spawn("f", spawner).tell("charlie")

        let spawnedBy = try p.expectMessage()
        pinfo("Spawned by: \(spawnedBy)")

        try p.expectNoMessage(for: .milliseconds(200))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Stopping actors

    func test_stopping_shouldDeinitTheBehavior() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe("p1")
        let chattyAboutLifecycle =
            try system.spawn("deinitLifecycleActor", .class { LifecycleDeinitClassBehavior(p.ref) })

        chattyAboutLifecycle.tell(.stop)

        try p.expectMessage("init")
        try p.expectMessage("receive:stop")
        try p.expectMessage("signal:PostStop()")
        try p.expectMessage("deinit")
    }
}

private enum LifecycleDeinitActorMessage: String, ActorMessage {
    case stop
}

private final class LifecycleDeinitClassBehavior: ClassBehavior<LifecycleDeinitActorMessage> {
    let probe: ActorRef<String>

    init(_ p: ActorRef<String>) {
        self.probe = p
        self.probe.tell("init")
    }

    deinit {
        self.probe.tell("deinit")
    }

    override func receive(context: ActorContext<LifecycleDeinitActorMessage>, message: LifecycleDeinitActorMessage) -> Behavior<LifecycleDeinitActorMessage> {
        self.probe.tell("receive:\(message)")
        return .stop
    }

    override func receiveSignal(context: ActorContext<LifecycleDeinitActorMessage>, signal: Signal) -> Behavior<LifecycleDeinitActorMessage> {
        self.probe.tell("signal:\(signal)")
        return .same
    }
}
