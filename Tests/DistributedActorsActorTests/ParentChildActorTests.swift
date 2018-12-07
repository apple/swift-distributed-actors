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
        case throwWhoops
    }

    typealias ParentChildProbeRef = ActorRef<ParentChildProbeProtocol>
    enum ParentChildProbeProtocol: Equatable {
        case spawned(child: ChildRef)
        case spawnFailed(path: ActorPath)

        case childNotFound(name: String)
        case childFound(name: String, ref: ChildRef)
        case childStopped(name: String)
    }

    enum ChildError: Error {
        case whoops
    }

    func parentBehavior(probe: ParentChildProbeRef, notifyWhenChildStops: Bool = false) -> Behavior<ParentProtocol> {
        return Behavior<ParentProtocol>.receive { context, message in
            switch message {
            case let .spawnChild(behavior, name):
                do {
                    let kid = try context.spawn(behavior, name: name)
                    if notifyWhenChildStops {
                        context.watch(kid)
                    }
                    probe.tell(.spawned(child: kid))
                } catch let ActorContextError.duplicateActorPath(path) {
                    probe.tell(.spawnFailed(path: path))
                } // bubble up others

            case let .findByName(name):
                if let found = context.children.find(named: name, withType: ChildProtocol.self) {
                    probe.tell(.childFound(name: name, ref: found))
                } else {
                    probe.tell(.childNotFound(name: name))
                }

            case .stopByName(let name):
                if let kid = context.children.find(named: name, withType: ChildProtocol.self) {
                    try context.stop(child: kid) // FIXME must allow plain try
                    probe.tell(.childFound(name: name, ref: kid))
                } else {
                    probe.tell(.childNotFound(name: name))
                }
            }

            return .same
        }.receiveSignal { (context, signal) in
            switch signal {
            case let .terminated(ref, _):
                if notifyWhenChildStops {
                    probe.tell(.childStopped(name: ref.path.name))
                }
            default:
                ()
            }
            return .same
        }
    }

    func childBehavior(probe: ParentChildProbeRef)  -> Behavior<ChildProtocol> {
        return .setup { context in
            context.log.info("Hello...")
            probe.tell(.spawned(child: context.myself))

            return .receiveMessage { message in
                switch message {
                case let .howAreYou(replyTo):
                    replyTo.tell("Pretty good, I'm \(context.path)")
                case .fail:
                    fatalError("Ohh no~!")
                case .throwWhoops:
                    throw ChildError.whoops
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

    func test_contextSpawn_duplicateNameShouldFail() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn(self.parentBehavior(probe: p.ref), name: "parent-2")
        parent.tell(.spawnChild(behavior: childBehavior(probe: p.ref), name: "kid"))

        _ = try p.expectMessageMatching { x throws -> ActorRef<ChildProtocol>? in
            switch x {
            case let .spawned(child): return child
            default: return nil
            }
        }

        parent.tell(.spawnChild(behavior: childBehavior(probe: p.ref), name: "kid"))

        _ = try p.expectMessageMatching { x throws -> ActorPath? in
            switch x {
            case let .spawnFailed(path): return path
            default: return nil
            }
        }
    }

    func test_contextStop_shouldStopChild() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn(self.parentBehavior(probe: p.ref, notifyWhenChildStops: true), name: "parent-3")

        parent.tell(.spawnChild(behavior: childBehavior(probe: p.ref), name: "kid"))

        _ = try p.expectMessageMatching { x throws -> ActorRef<ChildProtocol>? in
            switch x {
            case let .spawned(child): return child
            default: return nil
            }
        }

        parent.tell(.stopByName(name: "kid"))

        _ = try p.expectMessageMatching { x throws -> String? in
            switch x {
            case .childFound(name: "kid", _): return name
            default: return nil
            }
        }

        try p.expectMessage(.childStopped(name: "kid"))
    }

    func test_contextStop_shouldThrowIfRefIsNotChild() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let parent: ActorRef<String> = try system.spawn(.receive { (context, msg) in
            try context.stop(child: p.ref)
            return .same
        }, name: "parent-4")

        p.watch(parent)

        parent.tell("stop")

        try p.expectTerminated(parent)
    }

    func test_spawnStopSpawn_shouldWorkWithSameChildName() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let parent: ActorRef<String> = try system.spawnAnonymous(.receive { (context, msg) in
            switch msg {
            case "spawn":
                let refA: ActorRef<ChildProtocol> = try context.spawn(.setup { context in
                    p.tell(.spawned(child: context.myself))
                    return .ignore
                }, name: "child")

                p.watch(refA)
                try context.stop(child: refA)

                let refB: ActorRef<ChildProtocol> = try context.spawn(.setup { context in
                    p.tell(.spawned(child: context.myself))
                    return .ignore
                    }, name: "child")

                try context.stop(child: refB)
                return .same
            default:
                return .ignore
            }
        })

        p.watch(parent)

        parent.tell("spawn")

        let childA: ActorRef<ChildProtocol> = try p.expectMessageMatching {
            switch $0 {
            case let .spawned(child: ref):
                return ref
            default:
                return nil
            }
        }

        try p.expectTerminated(childA)

        _ = try p.expectMessageMatching { msg throws -> ActorRef<ChildProtocol>? in
            switch msg {
            case let .spawned(child: ref):
                return ref
            default:
                return nil
            }
        }
    }

    func test_throwOfSpawnedChild_shouldNotCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let stoppingChildBehavior: Behavior<ChildProtocol> = self.childBehavior(probe: p.ref)

        let parentBehavior = Behavior<String>.receive { (context, msg) in
            switch msg {
            case "spawn":
                _ = try context.spawn(stoppingChildBehavior, name: "child")
                return .same
            default:
                return .ignore
            }
        }

        let parent: ActorRef<String> = try system.spawn(parentBehavior, name: "watchingParent")

        p.watch(parent)
        parent.tell("spawn")

        let child: ActorRef<ChildProtocol> = try p.expectMessageMatching {
            guard case .spawned(let ref) = $0 else { return nil }
            return p.watch(ref)
        }

        sleep(1)
        // FIXME: remove the sleep; without it it currently races somewhat...
        // FIXME: since the probe's watch races with the failing so we may end up watching a terminated one,
        // FIXME: which may end up not being processed properly: this is bug: https://github.com/apple/swift-distributed-actors/issues/139

        child.tell(.throwWhoops)

        // since the parent watched the child, it will also terminate
        try p.expectTerminated(child)
        try p.expectNoTerminationSignal(for: .milliseconds(200))

        // yet it MUST allow spawning another child with the same name now, since the previous one has terminated
        parent.tell("spawn")

        let secondChild: ActorRef<ChildProtocol> = try p.expectMessageMatching {
            guard case .spawned(let ref) = $0 else { return nil }
            return p.watch(ref)
        }
    }

    func test_throwOfWatchedSpawnedChild_shouldCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = testKit.spawnTestProbe()

        let stoppingChildBehavior = self.childBehavior(probe: p.ref)

        let parentBehavior = Behavior<String>.receive { (context, msg) in
            switch msg {
            case "spawn":
                _ = try context.watch(context.spawn(stoppingChildBehavior, name: "child"))
                return .same
            default:
                return .ignore
            }
        }

        let parent: ActorRef<String> = try system.spawn(parentBehavior, name: "watchingParent")

        p.watch(parent)
        parent.tell("spawn")

        let child: ActorRef<ChildProtocol> = try p.expectMessageMatching {
            guard case .spawned(let ref) = $0 else { return nil }
            return p.watch(ref)
        }

        sleep(1)
        // FIXME: remove the sleep; without it it currently races somewhat...
        // FIXME: since the probe's watch races with the failing so we may end up watching a terminated one,
        // FIXME: which may end up not being processed properly: this is bug: https://github.com/apple/swift-distributed-actors/issues/139

        child.tell(.throwWhoops)

        // since the parent watched the child, it will also terminate
        try p.expectTerminated(child)
        try p.expectTerminated(parent)
    }

    // TODO test with watching the child actor
}
