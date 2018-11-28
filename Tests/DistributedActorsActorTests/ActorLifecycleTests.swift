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

class ActorLifecycleTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }

    // MARK: starting actors

    func test_spawn_shouldNotAllowStartingWith_Same() throws {
        // since there is no previous behavior to stay "same" name at the same time:

        let ex = shouldThrow {
            let sameBehavior: Behavior<String> = .same
            let _ = try self.system.spawn(sameBehavior, name: "same")
        }

        "\(ex)".shouldEqual("""
                            notAllowedAsInitial(Swift Distributed ActorsActor.Behavior<Swift.String>.same)
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
            let _ = try system.spawn(unhandledBehavior, name: "unhandled")
        }

        "\(ex)".shouldEqual("notAllowedAsInitial(Swift Distributed ActorsActor.Behavior<Swift.String>.unhandled)")
    }

    func test_spawn_shouldNotAllowIllegalActorNames() throws {
        func check(illegalName: String, expectedError: String) throws {
            let err = shouldThrow {
                let b: Behavior<String> = .ignore

                // more coverage for all the different chars in [[ActorPathTests]]
                let _ = try system.spawn(b, name: illegalName)
            }
            "\(err)".shouldEqual(expectedError)
        }

        try check(illegalName: "hello world", expectedError: """
                                                             illegalActorPathElement(name: "hello world", illegal: " ", index: 5)
                                                             """)

        try check(illegalName: "he//o", expectedError: """
                                                       illegalActorPathElement(name: "he//o", illegal: "/", index: 2)
                                                       """)
        try check(illegalName: "ążŻŌżąć", expectedError: """
                                                         illegalActorPathElement(name: "ążŻŌżąć", illegal: "ą", index: 0)
                                                         """)
        try check(illegalName: "カピバラ", expectedError: """
                                                      illegalActorPathElement(name: "カピバラ", illegal: "カ", index: 0)
                                                      """) // ka-pi-ba-ra
    }

    func test_spawn_shouldThrowFromMultipleActorsWithTheSamePathBeingSpawned() {
        pnote("NOT IMPLEMENTED YET")
    }

    func test_stopping_shouldDeinitTheBehavior() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe(name: "p1")
        let chattyAboutLifecycle =
            try system.spawn(LifecycleDeinitActorBehavior(p.ref), name: "deinitLifecycleActor")

        chattyAboutLifecycle.tell(.stop)

        try p.expectMessage("init")
        try p.expectMessage("receive:stop")
        // TODO: historically we have a "postStop" before dying; and we need it for the "not a class" behaviors anyway, implement this
        try p.expectMessage("deinit")
    }

}

enum LifecycleDeinitActorMessage {
    case stop
}

final class LifecycleDeinitActorBehavior: ActorBehavior<LifecycleDeinitActorMessage> {
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
        return .stopped
    }

    override func receiveSignal(context: ActorContext<LifecycleDeinitActorMessage>, signal: Signal) -> Behavior<LifecycleDeinitActorMessage> {
        self.probe.tell("signal:\(signal)")
        return .same
    }
}
