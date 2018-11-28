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

class ParentChildActorTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit: ActorTestKit = ActorTestKit(system)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }


    typealias ParentRef = ActorRef<ParentProtocol>
    enum ParentProtocol {
        case spawnChild(behavior: Behavior<ChildProtocol>, name: String)

        case stopByName(name: String)
        case findByName(name: String)
    }

    typealias ChildRef = ActorRef<ChildProtocol>
    enum ChildProtocol {
        case howAreYou(replyTo: ActorRef<String>)
        case fail
    }

    typealias ParentChildProbeRef = ActorRef<ParentChildProbeProtocol>
    enum ParentChildProbeProtocol: Equatable {
        case spawned(child: ChildRef)

        case childNotFound(name: String)
        case childFound(name: String,ref: ChildRef)
    }

    enum ChildError: Error {
        case whoops
    }

    func parentBehavior(probe: ParentChildProbeRef) -> Behavior<ParentProtocol> {
        return .receive { context, message in
            switch message {
            case let .spawnChild(behavior, name):
                let kid = try! context.spawn(behavior, name: name) // FIXME we MUST allow `try context.spawn`
                probe.tell(.spawned(child: kid))

            case let .findByName(name):
                if let found = context.children.find(named: name, withType: ChildProtocol.self) {
                    probe.tell(.childFound(name: name, ref: found))
                } else {
                    probe.tell(.childNotFound(name: name))
                }

            case .stopByName(let name):
                if let kid = context.children.find(named: name, withType: ChildProtocol.self) {
                    try! context.stop(child: kid) // FIXME must allow plain try
                    probe.tell(.childFound(name: name, ref: kid))
                } else {
                    probe.tell(.childNotFound(name: name))
                }
            }

            return .same
        }
    }

    func childBehavior(probe: ParentChildProbeRef)  -> Behavior<ChildProtocol> {
        return .setup { context in
            context.log.info("Hello...")
            return .receiveMessage { message in
                switch message {
                case let .howAreYou(replyTo):
                    replyTo.tell("Pretty good, I'm \(context.path)")
                case .fail:
                    // FIXME: Can't throw here yet... throw ChildError.whoops
                    fatalError("TODO")
                }
                return .same
            }
        }
    }

    func test_contextSpawn_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn(self.parentBehavior(probe: p.ref), name: "parent")
        parent.tell(.spawnChild(behavior: childBehavior(probe: p.ref), name: "kid"))

        // TODO: maybe fishForMessage would make this nicer?
        let child: ActorRef<ChildProtocol> = try p.expectMessageMatching {
            switch $0 {
            case let .spawned(child): return child
            default: return nil
            }
        }
        pnote("Hello: \(child)")

        let unknownName = "capybara"
        parent.tell(.findByName(name: unknownName))
        try p.expectMessage(.childNotFound(name: unknownName))

        parent.tell(.findByName(name: child.path.name))
        try p.expectMessage(.childFound(name: child.path.name, ref: child)) // should return same (or equal) ref

        parent.tell(.stopByName(name: child.path.name)) // stopping by name
        try p.expectMessage(.childFound(name: child.path.name, ref: child)) // we get the same, now dead, ref back

//        // FIXME This is not yet correct... stopping needs more work
//        // we expect the child actor to be dead now
//        p.watch(child) // watching dead ref triggers terminated
//        try p.expectTerminated(child)
//
//        parent.tell(.findByName(name: child.path.name)) // should not find that child anymore, it was stopped
//        try p.expectMessage(.childNotFound(name: child.path.name))

    }

    // TODO test with watching the child actor
}
