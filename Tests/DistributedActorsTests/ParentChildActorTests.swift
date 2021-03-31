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

final class ParentChildActorTests: ActorSystemXCTestCase {
    typealias ParentRef = ActorRef<ParentProtocol>
    enum ParentProtocol: NonTransportableActorMessage {
        case spawnChild(name: String, behavior: Behavior<ChildProtocol>)
        case spawnAnonymousChild(behavior: Behavior<ChildProtocol>)

        case stopByName(name: String)
        case findByName(name: String)
        case stop
    }

    typealias ChildRef = ActorRef<ChildProtocol>
    enum ChildProtocol: NonTransportableActorMessage {
        case howAreYou(replyTo: ActorRef<String>)
        case fail
        case throwWhoops
        case spawnChild(name: String, behavior: Behavior<ChildProtocol>)
    }

    typealias ParentChildProbeRef = ActorRef<ParentChildProbeProtocol>
    enum ParentChildProbeProtocol: Equatable, NonTransportableActorMessage {
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
        Behavior<ParentProtocol>.receive { context, message in
            switch message {
            case .stop:
                return .stop
            case .spawnChild(let name, let behavior):
                do {
                    let kid = try context.spawn(.unique(name), behavior)
                    if notifyWhenChildStops {
                        context.watch(kid)
                    }
                    probe.tell(.spawned(child: kid))
                } catch let ActorContextError.duplicateActorPath(path) {
                    probe.tell(.spawnFailed(path: path))
                } // bubble up others
            case .spawnAnonymousChild(let behavior):
                do {
                    let kid = try context.spawn(.anonymous, behavior)
                    if notifyWhenChildStops {
                        context.watch(kid)
                    }
                    probe.tell(.spawned(child: kid))
                } catch let ActorContextError.duplicateActorPath(path) {
                    probe.tell(.spawnFailed(path: path))
                } // bubble up others

            case .findByName(let name):
                if let found = context.children.find(named: name, withType: ChildProtocol.self) {
                    probe.tell(.childFound(name: name, ref: found))
                } else {
                    probe.tell(.childNotFound(name: name))
                }

            case .stopByName(let name):
                if let kid = context.children.find(named: name, withType: ChildProtocol.self) {
                    try context.stop(child: kid)
                    probe.tell(.childFound(name: name, ref: kid))
                } else {
                    probe.tell(.childNotFound(name: name))
                }
            }

            return .same
        }.receiveSignal { _, signal in
            switch signal {
            case let terminated as Signals.Terminated:
                if notifyWhenChildStops {
                    probe.tell(.childStopped(name: terminated.address.name))
                }
            default:
                ()
            }
            return .same
        }
    }

    func childBehavior(probe: ParentChildProbeRef, notifyWhenChildStops: Bool = false) -> Behavior<ChildProtocol> {
        .setup { context in
            context.log.debug("Hello...")

            return .receiveMessage { message in
                switch message {
                case .howAreYou(let replyTo):
                    replyTo.tell("Pretty good, I'm \(context.path)")
                case .fail:
                    fatalError("Ohh no~!")
                case .throwWhoops:
                    throw ChildError.whoops
                case .spawnChild(let name, let behavior):
                    do {
                        let kid = try context.spawn(.unique(name), behavior)
                        if notifyWhenChildStops {
                            context.watch(kid)
                        }
                        probe.tell(.spawned(child: kid))
                    } catch let ActorContextError.duplicateActorPath(path) {
                        probe.tell(.spawnFailed(path: path))
                    } // bubble up others
                }
                return .same
            }
        }
    }

    func test_contextSpawn_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }

        let unknownName = "capybara"
        parent.tell(.findByName(name: unknownName))
        try p.expectMessage(.childNotFound(name: unknownName))

        parent.tell(.findByName(name: child.address.name))
        try p.expectMessage(.childFound(name: child.address.name, ref: child)) // should return same (or equal) ref

        parent.tell(.stopByName(name: child.address.name)) // stopping by name
        try p.expectMessage(.childFound(name: child.address.name, ref: child)) // we get the same, now dead, ref back

        p.watch(child) // watching dead ref triggers terminated
        try p.expectTerminated(child)

        parent.tell(.findByName(name: child.address.name)) // should not find that child anymore, it was stopped
        try p.expectMessage(.childNotFound(name: child.address.name))
    }

    func test_contextSpawnAnonymous_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnAnonymousChild(behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }

        parent.tell(.findByName(name: child.address.name))
        try p.expectMessage(.childFound(name: child.address.name, ref: child)) // should return same (or equal) ref

        parent.tell(.stopByName(name: child.address.name)) // stopping by name
        try p.expectMessage(.childFound(name: child.address.name, ref: child)) // we get the same, now dead, ref back

        p.watch(child) // watching dead ref triggers terminated
        try p.expectTerminated(child)

        parent.tell(.findByName(name: child.address.name)) // should not find that child anymore, it was stopped
        try p.expectMessage(.childNotFound(name: child.address.name))
    }

    func test_contextSpawn_duplicateNameShouldFail() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn("parent-2", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        _ = try p.expectMessageMatching { x throws -> ActorRef<ChildProtocol>? in
            switch x {
            case .spawned(let child): return child
            default: return nil
            }
        }

        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        _ = try p.expectMessageMatching { x throws -> ActorPath? in
            switch x {
            case .spawnFailed(let path): return path
            default: return nil
            }
        }
    }

    func test_contextStop_shouldStopChild() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parent: ActorRef<ParentProtocol> = try system.spawn("parent-3", self.parentBehavior(probe: p.ref, notifyWhenChildStops: true))

        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned = try p.expectMessage() else { throw p.error() }

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
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let parent: ActorRef<String> = try system.spawn(
            "parent-4",
            .receive { context, _ in
                do {
                    try context.stop(child: p.ref)
                } catch {
                    p.tell("Errored:\(error)")
                    throw error // throw as if we did not catch it
                }
                return .same
            }
        )

        p.watch(parent)

        parent.tell("stop")

        try p.expectMessage().shouldStartWith(prefix: "Errored:attemptedStoppingNonChildActor(ref: AddressableActorRef(/user/$testProbe")
        try p.expectTerminated(parent)
    }

    func test_contextStop_shouldThrowIfRefIsMyself() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let parent: ActorRef<String> = try system.spawn(
            "parent-5",
            .receive { context, _ in
                do {
                    try context.stop(child: context.myself)
                } catch {
                    p.tell("Errored:\(error)")
                    throw error // throw as if we did not catch it
                }
                return .same
            }
        )

        p.watch(parent)

        parent.tell("stop")

        try p.expectMessage().shouldStartWith(prefix: "Errored:attemptedStoppingMyselfUsingContext(ref: AddressableActorRef(/user/parent-5")
        try p.expectTerminated(parent)
    }

    func test_spawnStopSpawn_shouldWorkWithSameChildName() throws {
        let p: ActorTestProbe<Never> = self.testKit.spawnTestProbe("p")
        let p1: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe("p1")
        let p2: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe("p2")

        let parent: ActorRef<String> = try system.spawn(
            .anonymous,
            .receive { context, msg in
                switch msg {
                case "spawn":
                    let refA: ActorRef<ChildProtocol> = try context.spawn(
                        "child",
                        .setup { context in
                            p1.tell(.spawned(child: context.myself))
                            return .ignore
                        }
                    )
                    try context.stop(child: refA)

                    let refB: ActorRef<ChildProtocol> = try context.spawn(
                        "child",
                        .setup { context in
                            p2.tell(.spawned(child: context.myself))
                            return .ignore
                        }
                    )
                    try context.stop(child: refB)

                    return .same
                default:
                    return .ignore
                }
            }
        )

        p.watch(parent)
        parent.tell("spawn")

        // TODO: would be useful to provide some expectSpawned since it's such a common thing
        guard case .spawned(let childA) = try p1.expectMessage() else { throw p1.error() }
        p1.watch(childA)
        guard case .spawned(let childB) = try p2.expectMessage() else { throw p2.error() }
        p2.watch(childB)

        try p1.expectTerminated(childA, within: .milliseconds(500))
        try p2.expectTerminated(childB, within: .milliseconds(500))
        try p.expectNoTerminationSignal(for: .milliseconds(100))
    }

    func test_throwOfSpawnedChild_shouldNotCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let childBehavior: Behavior<ChildProtocol> = self.childBehavior(probe: p.ref)

        let parentBehavior = Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context.spawn("child", childBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }

        let parent: ActorRef<String> = try system.spawn("watchingParent", parentBehavior)

        p.watch(parent)
        parent.tell("spawn")

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }
        p.watch(child)

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

        secondChild.address.path.shouldEqual(child.address.path)
        secondChild.address.incarnation.shouldNotEqual(child.address.incarnation)
    }

    func test_throwOfWatchedSpawnedChild_shouldCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let stoppingChildBehavior = self.childBehavior(probe: p.ref)

        let parentBehavior = Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context.spawnWatch("child", stoppingChildBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }

        let parent: ActorRef<String> = try system.spawn("watchingParent", parentBehavior)

        p.watch(parent)
        parent.tell("spawn")

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }
        p.watch(child)

        child.tell(.throwWhoops)

        // since the parent watched the child, it will also terminate
        try p.expectTerminatedInAnyOrder([child.asAddressable, parent.asAddressable])
    }

    func test_watchedChild_shouldProduceInSingleTerminatedSignal() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()
        let pChild: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let childBehavior: Behavior<ChildProtocol> = self.childBehavior(probe: p.ref)

        let parentBehavior = Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context.spawnWatch("child", childBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }.receiveSignal { _, signal in
            switch signal {
            case let terminated as Signals.ChildTerminated:
                // only this should match
                p.tell(.childStopped(name: "child-term:\(terminated.address.name)"))
            case let terminated as Signals.Terminated:
                // no second "generic" terminated should be sent (though one could match for just Terminated)
                p.tell(.childStopped(name: "term:\(terminated.address.name)"))
            default:
                return .ignore
            }
            return .same
        }

        let parent: ActorRef<String> = try system.spawn("watchingParent", parentBehavior)

        p.watch(parent)
        parent.tell("spawn")

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }
        p.watch(child)

        child.tell(.howAreYou(replyTo: pChild.ref))
        _ = try pChild.expectMessage() // only expecting the ping pong to give parent time enough to watch the child "properly" and not its dead cell

        child.tell(.throwWhoops)

        // since the parent watched the child, it will also terminate
        try p.expectTerminated(child)
        switch try p.expectMessage() {
        case .childStopped(let name):
            name.shouldEqual("child-term:child")
        default:
            throw p.error()
        }
        try p.expectNoMessage(for: .milliseconds(100)) // no second terminated should happen
    }

    func test_spawnWatch_shouldSpawnAWatchedActor() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parentBehavior: Behavior<String> = .receive { context, message in
            switch message {
            case "spawn":
                let childRef: ChildRef = try context.spawnWatch("child", .stop)
                p.tell(.spawned(child: childRef))
            default:
                ()
            }
            return .same
        }

        let parent = try system.spawn(
            .anonymous,
            parentBehavior.receiveSignal { _, signal in
                if case let terminated as Signals.Terminated = signal {
                    p.tell(.childStopped(name: terminated.address.name))
                }

                return .same
            }
        )

        parent.tell("spawn")

        guard case .spawned(let childRef) = try p.expectMessage() else { throw p.error() }
        guard case .childStopped(let name) = try p.expectMessage() else { throw p.error() }

        childRef.address.name.shouldEqual(name)
    }

    func test_stopParent_shouldWaitForChildrenToStop() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testKit.spawnTestProbe()

        let parent = try system.spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "child", behavior: self.childBehavior(probe: p.ref)))
        p.watch(parent)

        guard case .spawned(let childRef) = try p.expectMessage() else { throw p.error() }
        p.watch(childRef)

        childRef.tell(.spawnChild(name: "grandChild", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let grandchildRef) = try p.expectMessage() else { throw p.error() }
        p.watch(grandchildRef)

        parent.tell(.stop)

        try p.expectTerminatedInAnyOrder([parent.asAddressable, childRef.asAddressable, grandchildRef.asAddressable])
    }

    func test_spawnStopSpawnManyTimesWithSameName_shouldProperlyTerminateAllChildren() throws {
        let p: ActorTestProbe<Int> = self.testKit.spawnTestProbe("p")
        let childCount = 100

        let parent: ActorRef<String> = try system.spawn(
            .anonymous,
            .receive { context, msg in
                switch msg {
                case "spawn":
                    for count in 1 ... childCount {
                        let behavior: Behavior<Int> = .receiveMessage { _ in .ignore }
                        let ref: ActorRef<Int> = try context.spawn(
                            "child",
                            behavior.receiveSignal { _, signal in
                                if signal is Signals.PostStop {
                                    p.tell(count)
                                }

                                return .same
                            }
                        )
                        try context.stop(child: ref)
                    }

                    return .same
                default:
                    return .ignore
                }
            }
        )

        parent.tell("spawn")

        let messages = try p.expectMessages(count: childCount)
        messages.sorted().shouldEqual((1 ... childCount).sorted())
    }
}
