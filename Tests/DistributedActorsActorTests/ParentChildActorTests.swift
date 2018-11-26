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
import Swift Distributed ActorsActorTestkit

class ParentChildActorTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit: ActorTestKit = ActorTestKit(system: system)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }


    typealias ParentRef = ActorRef<ParentProtocol>
    enum ParentProtocol {
        case spawnChild(behavior: Behavior<ChildProtocol>, name: String)
        case stopChild(name: String)
    }

    typealias ChildRef = ActorRef<ChildProtocol>
    enum ChildProtocol {
        case howAreYou(replyTo: ActorRef<String>)
        case fail
    }

    typealias ParentChildProbeRef = ActorRef<ParentChildProbeProtocol>
    enum ParentChildProbeProtocol {
        case spawned(child: ActorRef<ChildProtocol>)
    }

    func parent(probe: ParentChildProbeRef) -> Behavior<ParentProtocol> {
        return .receive { context, message in
            switch message {
            case let .spawnChild(behavior, name):
                let kid = try! context.spawn(behavior, name: name) // FIXME we MUST allow `try context.spawn`
                probe.tell(.spawned(child: kid))

            case .stopChild(let name):
                guard let kid = context.children.find(named: name) else { fatalError() }
                context.stop(child: kid!) // FIXME must allow `try context.stop`
                    probe.tell("stopped \(kid!.path)")
                } else {
                    probe.tell("child actor not found: \(name)")
                }
            }

            return .same
        }
    }

    func child(probe: ParentChildProbeRef)  -> Behavior<ChildProtocol> {
        return .setup { context in
            context.log.info("Hello...")
            probe.tell("setup in \(context.path)")
            return .receiveMessage { message in
                context.log.info("Received \(message)")
                return .same
            }
        }
    }

    func test_contextSpawn_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = .init(name: "p", on: system)

        let parent: ActorRef<ParentProtocol> = try system.spawn(self.parent(probe: p.ref), name: "parent")
        parent.tell(.spawnChild(behavior: child(probe: p.ref), name: "kid"))

        try p.expectMessage("spawned kid")
        try p.expectMessage("setup in /user/parent/kid")
        parent.tell(.stopChild(name: "kid"))
    }

    // TODO test with watching the child actor
}
