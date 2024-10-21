//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ParentChildActorTests {
    typealias ParentRef = _ActorRef<ParentProtocol>
    enum ParentProtocol: _NotActuallyCodableMessage {
        case spawnChild(name: String, behavior: _Behavior<ChildProtocol>)
        case spawnAnonymousChild(behavior: _Behavior<ChildProtocol>)

        case stopByName(name: String)
        case findByName(name: String)
        case stop
    }

    typealias ChildRef = _ActorRef<ChildProtocol>
    enum ChildProtocol: _NotActuallyCodableMessage {
        case howAreYou(replyTo: _ActorRef<String>)
        case fail
        case throwWhoops
        case makeChild(name: String, behavior: _Behavior<ChildProtocol>)
    }

    typealias ParentChildProbeRef = _ActorRef<ParentChildProbeProtocol>
    enum ParentChildProbeProtocol: Equatable, _NotActuallyCodableMessage {
        case spawned(child: ChildRef)
        case spawnFailed(path: ActorPath)

        case childNotFound(name: String)
        case childFound(name: String, ref: ChildRef)
        case childStopped(name: String)
    }

    enum ChildError: Error {
        case whoops
    }

    func parentBehavior(probe: ParentChildProbeRef, notifyWhenChildStops: Bool = false) -> _Behavior<ParentProtocol> {
        _Behavior<ParentProtocol>.receive { context, message in
            switch message {
            case .stop:
                return .stop
            case .spawnChild(let name, let behavior):
                do {
                    let kid = try context._spawn(.unique(name), behavior)
                    if notifyWhenChildStops {
                        context.watch(kid)
                    }
                    probe.tell(.spawned(child: kid))
                } catch let error as _ActorContextError {
                    if case .duplicateActorPath(let path, _) = error.underlying.error {
                        probe.tell(.spawnFailed(path: path))
                    } else {
                        throw error
                    }
                } // bubble up others
            case .spawnAnonymousChild(let behavior):
                do {
                    let kid = try context._spawn(.anonymous, behavior)
                    if notifyWhenChildStops {
                        context.watch(kid)
                    }
                    probe.tell(.spawned(child: kid))
                } catch let error as _ActorContextError {
                    if case .duplicateActorPath(let path, _) = error.underlying.error {
                        probe.tell(.spawnFailed(path: path))
                    } else {
                        throw error
                    }
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
            case let terminated as _Signals.Terminated:
                if notifyWhenChildStops {
                    probe.tell(.childStopped(name: terminated.id.name))
                }
            default:
                ()
            }
            return .same
        }
    }

    func childBehavior(probe: ParentChildProbeRef, notifyWhenChildStops: Bool = false) -> _Behavior<ChildProtocol> {
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
                case .makeChild(let name, let behavior):
                    do {
                        let kid = try context._spawn(.unique(name), behavior)
                        if notifyWhenChildStops {
                            context.watch(kid)
                        }
                        probe.tell(.spawned(child: kid))
                    } catch let error as _ActorContextError {
                        if case .duplicateActorPath(let path, _) = error.underlying.error {
                            probe.tell(.spawnFailed(path: path))
                        } else {
                            throw error
                        }
                    } // bubble up others
                }
                return .same
            }
        }
    }

    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }

    @Test
    func test_contextSpawn_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<ParentProtocol> = try self.testCase.system._spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }

        let unknownName = "capybara"
        parent.tell(.findByName(name: unknownName))
        try p.expectMessage(.childNotFound(name: unknownName))

        parent.tell(.findByName(name: child.id.name))
        try p.expectMessage(.childFound(name: child.id.name, ref: child)) // should return same (or equal) ref

        parent.tell(.stopByName(name: child.id.name)) // stopping by name
        try p.expectMessage(.childFound(name: child.id.name, ref: child)) // we get the same, now dead, ref back

        p.watch(child) // watching dead ref triggers terminated
        try p.expectTerminated(child)

        parent.tell(.findByName(name: child.id.name)) // should not find that child anymore, it was stopped
        try p.expectMessage(.childNotFound(name: child.id.name))
    }

    @Test
    func test_contextSpawnAnonymous_shouldSpawnChildActorOnAppropriatePath() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<ParentProtocol> = try self.testCase.system._spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnAnonymousChild(behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }

        parent.tell(.findByName(name: child.id.name))
        try p.expectMessage(.childFound(name: child.id.name, ref: child)) // should return same (or equal) ref

        parent.tell(.stopByName(name: child.id.name)) // stopping by name
        try p.expectMessage(.childFound(name: child.id.name, ref: child)) // we get the same, now dead, ref back

        p.watch(child) // watching dead ref triggers terminated
        try p.expectTerminated(child)

        parent.tell(.findByName(name: child.id.name)) // should not find that child anymore, it was stopped
        try p.expectMessage(.childNotFound(name: child.id.name))
    }

    @Test
    func test_contextSpawn_duplicateNameShouldFail() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<ParentProtocol> = try self.testCase.system._spawn("parent-2", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        _ = try p.expectMessageMatching { x throws -> _ActorRef<ChildProtocol>? in
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

    @Test
    func test_contextStop_shouldStopChild() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<ParentProtocol> = try self.testCase.system._spawn("parent-3", self.parentBehavior(probe: p.ref, notifyWhenChildStops: true))

        parent.tell(.spawnChild(name: "kid", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned = try p.expectMessage() else { throw p.error() }

        parent.tell(.stopByName(name: "kid"))

        _ = try p.expectMessageMatching { x throws -> String? in
            switch x {
            case .childFound(name: "kid", _): return "kid" // name // FIXME: return name
            default: return nil
            }
        }

        try p.expectMessage(.childStopped(name: "kid"))
    }

    @Test
    func test_contextStop_shouldThrowIfRefIsNotChild() throws {
        let p: ActorTestProbe<String> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<String> = try self.testCase.system._spawn(
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

        try p.expectMessage().shouldStartWith(prefix: "Errored:_ActorContextError(attemptedStoppingNonChildActor(ref: _AddressableActorRef(/user/$testProbe")
        try p.expectTerminated(parent)
    }

    @Test
    func test_contextStop_shouldThrowIfRefIsMyself() throws {
        let p: ActorTestProbe<String> = self.testCase.testKit.makeTestProbe()

        let parent: _ActorRef<String> = try self.testCase.system._spawn(
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

        try p.expectMessage().shouldStartWith(prefix: "Errored:_ActorContextError(attemptedStoppingMyselfUsingContext(ref: _AddressableActorRef(/user/parent-5")
        try p.expectTerminated(parent)
    }

    @Test
    func test_spawnStopSpawn_shouldWorkWithSameChildName() throws {
        let p: ActorTestProbe<Never> = self.testCase.testKit.makeTestProbe("p")
        let p1: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe("p1")
        let p2: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe("p2")

        let parent: _ActorRef<String> = try self.testCase.system._spawn(
            .anonymous,
            .receive { context, msg in
                switch msg {
                case "spawn":
                    let refA: _ActorRef<ChildProtocol> = try context._spawn(
                        "child",
                        .setup { context in
                            p1.tell(.spawned(child: context.myself))
                            return .ignore
                        }
                    )
                    try context.stop(child: refA)

                    let refB: _ActorRef<ChildProtocol> = try context._spawn(
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

    @Test
    func test_throwOfSpawnedChild_shouldNotCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let childBehavior: _Behavior<ChildProtocol> = self.childBehavior(probe: p.ref)

        let parentBehavior = _Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context._spawn("child", childBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }

        let parent: _ActorRef<String> = try self.testCase.system._spawn("watchingParent", parentBehavior)

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

        let secondChild: _ActorRef<ChildProtocol> = try p.expectMessageMatching {
            guard case .spawned(let ref) = $0 else { return nil }
            return p.watch(ref)
        }

        secondChild.id.path.shouldEqual(child.id.path)
        secondChild.id.incarnation.shouldNotEqual(child.id.incarnation)
    }

    @Test
    func test_throwOfWatchedSpawnedChild_shouldCauseParentToTerminate() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let stoppingChildBehavior = self.childBehavior(probe: p.ref)

        let parentBehavior = _Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context._spawnWatch("child", stoppingChildBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }

        let parent: _ActorRef<String> = try self.testCase.system._spawn("watchingParent", parentBehavior)

        p.watch(parent)
        parent.tell("spawn")

        guard case .spawned(let child) = try p.expectMessage() else { throw p.error() }
        p.watch(child)

        child.tell(.throwWhoops)

        // since the parent watched the child, it will also terminate
        try p.expectTerminatedInAnyOrder([child.asAddressable, parent.asAddressable])
    }

    @Test
    func test_watchedChild_shouldProduceInSingleTerminatedSignal() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()
        let pChild: ActorTestProbe<String> = self.testCase.testKit.makeTestProbe()

        let childBehavior: _Behavior<ChildProtocol> = self.childBehavior(probe: p.ref)

        let parentBehavior = _Behavior<String>.receive { context, msg in
            switch msg {
            case "spawn":
                let childRef = try context._spawnWatch("child", childBehavior)
                p.tell(.spawned(child: childRef))
                return .same
            default:
                return .ignore
            }
        }.receiveSignal { _, signal in
            switch signal {
            case let terminated as _Signals._ChildTerminated:
                // only this should match
                p.tell(.childStopped(name: "child-term:\(terminated.id.name)"))
            case let terminated as _Signals.Terminated:
                // no second "generic" terminated should be sent (though one could match for just Terminated)
                p.tell(.childStopped(name: "term:\(terminated.id.name)"))
            default:
                return .ignore
            }
            return .same
        }

        let parent: _ActorRef<String> = try self.testCase.system._spawn("watchingParent", parentBehavior)

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

    @Test
    func test_spawnWatch_shouldSpawnAWatchedActor() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parentBehavior: _Behavior<String> = .receive { context, message in
            switch message {
            case "spawn":
                let childRef: ChildRef = try context._spawnWatch("child", .stop)
                p.tell(.spawned(child: childRef))
            default:
                ()
            }
            return .same
        }

        let parent = try self.testCase.system._spawn(
            .anonymous,
            parentBehavior.receiveSignal { _, signal in
                if case let terminated as _Signals.Terminated = signal {
                    p.tell(.childStopped(name: terminated.id.name))
                }

                return .same
            }
        )

        parent.tell("spawn")

        guard case .spawned(let childRef) = try p.expectMessage() else { throw p.error() }
        guard case .childStopped(let name) = try p.expectMessage() else { throw p.error() }

        childRef.id.name.shouldEqual(name)
    }

    @Test
    func test_stopParent_shouldWaitForChildrenToStop() throws {
        let p: ActorTestProbe<ParentChildProbeProtocol> = self.testCase.testKit.makeTestProbe()

        let parent = try self.testCase.system._spawn("parent", self.parentBehavior(probe: p.ref))
        parent.tell(.spawnChild(name: "child", behavior: self.childBehavior(probe: p.ref)))
        p.watch(parent)

        guard case .spawned(let childRef) = try p.expectMessage() else { throw p.error() }
        p.watch(childRef)

        childRef.tell(.makeChild(name: "grandChild", behavior: self.childBehavior(probe: p.ref)))

        guard case .spawned(let grandchildRef) = try p.expectMessage() else { throw p.error() }
        p.watch(grandchildRef)

        parent.tell(.stop)

        try p.expectTerminatedInAnyOrder([parent.asAddressable, childRef.asAddressable, grandchildRef.asAddressable])
    }

    @Test
    func test_spawnStopSpawnManyTimesWithSameName_shouldProperlyTerminateAllChildren() throws {
        let p: ActorTestProbe<Int> = self.testCase.testKit.makeTestProbe("p")
        let childCount = 100

        let parent: _ActorRef<String> = try self.testCase.system._spawn(
            .anonymous,
            .receive { context, msg in
                switch msg {
                case "spawn":
                    for count in 1 ... childCount {
                        let behavior: _Behavior<Int> = .receiveMessage { _ in .ignore }
                        let ref: _ActorRef<Int> = try context._spawn(
                            "child",
                            behavior.receiveSignal { _, signal in
                                if signal is _Signals._PostStop {
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
