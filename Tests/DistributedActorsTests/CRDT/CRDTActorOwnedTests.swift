//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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
import XCTest

final class CRDTActorOwnedTests: XCTestCase {
    var logCaptureHandler: LogCapture!
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.logCaptureHandler = LogCapture()
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.overrideLogger = self.logCaptureHandler.makeLogger(label: settings.cluster.node.systemName)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.logCaptureHandler.printIfFailed(self.testRun)
        self.system.shutdown().wait()
    }

    private enum OwnerEventProbeMessage {
        case ownerDefinedOnUpdate
        case ownerDefinedOnDelete
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor-owned GCounter tests

    private enum GCounterCommand {
        case increment(amount: Int, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Int>)
        case read(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Int>)
        case delete(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Void>)

        case lastObservedValue(replyTo: ActorRef<Int>)
        case status(replyTo: ActorRef<CRDT.Status>)
    }

    private func actorOwnedGCounterBehavior(id: String, oep ownerEventProbe: ActorRef<OwnerEventProbeMessage>) -> Behavior<GCounterCommand> {
        return .setup { context in
            let g = CRDT.GCounter.owned(by: context, id: id)
            g.onUpdate { id, gg in
                context.log.trace("GCounter \(id) updated with new value: \(gg.value)", metadata: gg.metadata(context))
                ownerEventProbe.tell(.ownerDefinedOnUpdate)
            }
            g.onDelete { id in
                context.log.trace("GCounter \(id) deleted", metadata: g.data.metadata(context))
                ownerEventProbe.tell(.ownerDefinedOnDelete)
            }

            return .receiveMessage { message in
                switch message {
                case .increment(let amount, let consistency, let timeout, let replyTo):
                    g.increment(by: amount, writeConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let g):
                            replyTo.tell(g.value)
                        case .failure(let error):
                            fatalError("write error \(error)")
                        }
                    }
                case .read(let consistency, let timeout, let replyTo):
                    g.read(atConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let g):
                            replyTo.tell(g.value)
                        case .failure(let error):
                            fatalError("read error \(error)")
                        }
                    }
                case .delete(let consistency, let timeout, let replyTo):
                    g.deleteFromCluster(consistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success:
                            replyTo.tell(())
                        case .failure(let error):
                            fatalError("delete error \(error)")
                        }
                    }
                case .lastObservedValue(let replyTo):
                    replyTo.tell(g.lastObservedValue)
                case .status(let replyTo):
                    replyTo.tell(g.status)
                }
                return .same
            }
        }
    }

    func test_actorOwned_theLastWrittenOnUpdateCallbackWins() throws {
        let ownerEventPA = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let ownerEventPB = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)

        let behavior: Behavior<String> = .setup { context in
            let g = CRDT.GCounter.owned(by: context, id: "test-gcounter")
            g.onUpdate { _, _ in
                ownerEventPA.tell(.ownerDefinedOnUpdate)
            }
            // Overwrites the callback above
            g.onUpdate { _, _ in
                ownerEventPB.tell(.ownerDefinedOnUpdate)
            }

            return .receiveMessage { _ in
                _ = g.increment(by: 1, writeConsistency: .local, timeout: .milliseconds(100))
                return .same
            }
        }
        let owner = try system.spawn(.anonymous, behavior)

        owner.tell("hello")
        // Callback "B" replaced "A" so "A" should not receive message
        try ownerEventPB.expectMessage(.ownerDefinedOnUpdate)
        try ownerEventPA.expectNoMessage(for: .milliseconds(10))
    }

    func test_actorOwned_GCounter_increment_shouldNotifyOthers() throws {
        let g1 = "gcounter-1"
        let g2 = "gcounter-2"

        // TODO: remove after figuring out why tests are flakey (https://github.com/apple/swift-distributed-actors/issues/157)
        defer {
            self.logCaptureHandler.printLogs()
        }

        // g1 has two owners
        let g1Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner1 = try system.spawn("gcounter1-owner1", self.actorOwnedGCounterBehavior(id: g1, oep: g1Owner1EventP.ref))
        let g1Owner1IntP = self.testKit.spawnTestProbe(expecting: Int.self)

        let g1Owner2EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner2 = try system.spawn("gcounter1-owner2", self.actorOwnedGCounterBehavior(id: g1, oep: g1Owner2EventP.ref))
        let g1Owner2IntP = self.testKit.spawnTestProbe(expecting: Int.self)

        // g2 has one owner
        let g2Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g2Owner1 = try system.spawn("gcounter2-owner1", self.actorOwnedGCounterBehavior(id: g2, oep: g2Owner1EventP.ref))
        let g2Owner1IntP = self.testKit.spawnTestProbe(expecting: Int.self)

        // g1 not incremented yet
        g1Owner1.tell(.lastObservedValue(replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(0)

        // Increment g1 and the latest value should be returned
        g1Owner1.tell(.increment(amount: 3, consistency: .local, timeout: .milliseconds(100), replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(3)

        // g1 owner1's local value should be up-to-date
        g1Owner1.tell(.lastObservedValue(replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(3)

        // owner1 should be notified even if it triggered the action
        try g1Owner1EventP.expectMessage(.ownerDefinedOnUpdate)

        // owner2 should be notified about g1 updates, which means it should have up-to-date value too
        try g1Owner2EventP.expectMessage(.ownerDefinedOnUpdate)
        g1Owner2.tell(.lastObservedValue(replyTo: g1Owner2IntP.ref))
        try g1Owner2IntP.expectMessage(3)

        // g2 hasn't been mutated
        g2Owner1.tell(.read(consistency: .local, timeout: .milliseconds(100), replyTo: g2Owner1IntP.ref))
        try g2Owner1IntP.expectMessage(0)
        // As a result owner should not have received any events
        try g2Owner1EventP.expectNoMessage(for: .milliseconds(100))
    }

    // TODO: test that a failure to write gets logged?

    func test_actorOwned_GCounter_deleteFromCluster_shouldChangeStatus() throws {
        let g1 = "gcounter-1"

        // g1 has two owners
        let g1Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner1 = try system.spawn("gcounter1-owner1", self.actorOwnedGCounterBehavior(id: g1, oep: g1Owner1EventP.ref))
        let g1Owner1VoidP = self.testKit.spawnTestProbe(expecting: Void.self)
        let g1Owner1StatusP = self.testKit.spawnTestProbe(expecting: CRDT.Status.self)

        let g1Owner2EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner2 = try system.spawn("gcounter1-owner2", self.actorOwnedGCounterBehavior(id: g1, oep: g1Owner2EventP.ref))
        let g1Owner2StatusP = self.testKit.spawnTestProbe(expecting: CRDT.Status.self)

        // Should be .active
        g1Owner2.tell(.status(replyTo: g1Owner2StatusP.ref))
        try g1Owner2StatusP.expectMessage(.active)

        // owner1 makes call to delete g1
        g1Owner1.tell(.delete(consistency: .local, timeout: .milliseconds(100), replyTo: g1Owner1VoidP.ref))

        // owner1 should be notified even if it triggered the action
        try g1Owner1EventP.expectMessage(.ownerDefinedOnDelete)

        // owner2 should be notified as well
        try g1Owner2EventP.expectMessage(.ownerDefinedOnDelete)
        // And change status to .deleted
        g1Owner2.tell(.status(replyTo: g1Owner2StatusP.ref))
        try g1Owner2StatusP.expectMessage(.deleted)

        // owner1's g1 status should also be .deleted
        g1Owner1.tell(.status(replyTo: g1Owner1StatusP.ref))
        try g1Owner1StatusP.expectMessage(.deleted)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor-owned ORSet tests

    private enum ORSetCommand {
        case add(_ element: Int, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Set<Int>>)
        case remove(_ element: Int, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Set<Int>>)
        case read(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Set<Int>>)

        case lastObservedValue(replyTo: ActorRef<Set<Int>>)
    }

    private func actorOwnedORSetBehavior(id: String, oep ownerEventProbe: ActorRef<OwnerEventProbeMessage>) -> Behavior<ORSetCommand> {
        return .setup { context in
            let s = CRDT.ORSet<Int>.owned(by: context, id: id)
            s.onUpdate { id, ss in
                context.log.trace("ORSet \(id) updated with new value: \(ss.elements)")
                ownerEventProbe.tell(.ownerDefinedOnUpdate)
            }
            s.onDelete { id in
                context.log.trace("ORSet \(id) deleted")
                ownerEventProbe.tell(.ownerDefinedOnDelete)
            }

            return .receiveMessage { message in
                switch message {
                case .add(let element, let consistency, let timeout, let replyTo):
                    s.add(element, writeConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let s):
                            replyTo.tell(s.elements)
                        case .failure(let error):
                            fatalError("add error \(error)")
                        }
                    }
                case .remove(let element, let consistency, let timeout, let replyTo):
                    s.remove(element, writeConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let s):
                            replyTo.tell(s.elements)
                        case .failure(let error):
                            fatalError("remove error \(error)")
                        }
                    }
                case .read(let consistency, let timeout, let replyTo):
                    s.read(atConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let s):
                            replyTo.tell(s.elements)
                        case .failure(let error):
                            fatalError("read error \(error)")
                        }
                    }
                case .lastObservedValue(let replyTo):
                    replyTo.tell(s.lastObservedValue)
                }
                return .same
            }
        }
    }

    func test_actorOwned_ORSet_add_remove_shouldNotifyOthers() throws {
        let s1 = "orset-1"
        let s2 = "orset-2"

        // s1 has two owners
        let s1Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let s1Owner1 = try system.spawn("orset1-owner1", self.actorOwnedORSetBehavior(id: s1, oep: s1Owner1EventP.ref))
        let s1Owner1IntSetP = self.testKit.spawnTestProbe(expecting: Set<Int>.self)

        let s1Owner2EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let s1Owner2 = try system.spawn("orset1-owner2", self.actorOwnedORSetBehavior(id: s1, oep: s1Owner2EventP.ref))
        let s1Owner2IntSetP = self.testKit.spawnTestProbe(expecting: Set<Int>.self)

        // s2 has one owner
        let s2Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let s2Owner1 = try system.spawn("orset2-owner1", self.actorOwnedORSetBehavior(id: s2, oep: s2Owner1EventP.ref))
        let s2Owner1IntSetP = self.testKit.spawnTestProbe(expecting: Set<Int>.self)

        // s1 not modified yet
        s1Owner1.tell(.lastObservedValue(replyTo: s1Owner1IntSetP.ref))
        try s1Owner1IntSetP.expectMessage([])

        // Add element to s1 and the latest value should be returned
        s1Owner1.tell(.add(3, consistency: .local, timeout: .milliseconds(100), replyTo: s1Owner1IntSetP.ref))
        try s1Owner1IntSetP.expectMessage([3])

        // s1 owner1's local value should be up-to-date
        s1Owner1.tell(.lastObservedValue(replyTo: s1Owner1IntSetP.ref))
        try s1Owner1IntSetP.expectMessage([3])

        // owner1 should be notified even if it triggered the action
        try s1Owner1EventP.expectMessage(.ownerDefinedOnUpdate)

        // owner2 should be notified about s1 updates, which means it should have up-to-date value too
        try s1Owner2EventP.expectMessage(.ownerDefinedOnUpdate)
        s1Owner2.tell(.lastObservedValue(replyTo: s1Owner2IntSetP.ref))
        try s1Owner2IntSetP.expectMessage([3])

        // s2 hasn't been mutated
        s2Owner1.tell(.read(consistency: .local, timeout: .milliseconds(100), replyTo: s2Owner1IntSetP.ref))
        try s2Owner1IntSetP.expectMessage([])
        // As a result owner should not have received any events
        try s2Owner1EventP.expectNoMessage(for: .milliseconds(100))
    }

    // This test would uncover concurrency issues if the Owned updates were to fire concurrently, and not looped through the actor
    func test_actorOwned_ORSet_add_many_times() throws {
        let s1 = "set"

        let ignore: ActorRef<Set<Int>> = try system.spawn("ignore", .receiveMessage { _ in .same })
        let ignoreOEP: ActorRef<OwnerEventProbeMessage> = try system.spawn("ignoreOEP", .receiveMessage { _ in .same })

        let owner = try system.spawn("set-owner-1", self.actorOwnedORSetBehavior(id: s1, oep: ignoreOEP))
        let probe = self.testKit.spawnTestProbe(expecting: Set<Int>.self)

        // we issue many writes, and want to see that
        for i in 1 ... 100 {
            owner.tell(.add(i, consistency: .local, timeout: .seconds(1), replyTo: ignore))
        }
        owner.tell(.add(1000, consistency: .local, timeout: .seconds(1), replyTo: probe.ref))

        let msg = try probe.expectMessage()
        msg.count.shouldEqual(101)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor-owned ORMap tests

    private enum ORMapCommand {
        case increment(key: String, amount: Int, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<[String: CRDT.GCounter]>)
        case removeValue(key: String, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<[String: CRDT.GCounter]>)
        case read(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<[String: CRDT.GCounter]>)

        case lastObservedValue(replyTo: ActorRef<[String: CRDT.GCounter]>)
    }

    private func actorOwnedORMapBehavior(id: String, oep ownerEventProbe: ActorRef<OwnerEventProbeMessage>) -> Behavior<ORMapCommand> {
        return .setup { context in
            let m = CRDT.ORMap<String, CRDT.GCounter>.owned(by: context, id: id, valueInitializer: { CRDT.GCounter(replicaId: .actorAddress(context.address)) })
            m.onUpdate { id, mm in
                context.log.trace("ORMap \(id) updated with new value: \(mm.underlying)")
                ownerEventProbe.tell(.ownerDefinedOnUpdate)
            }
            m.onDelete { id in
                context.log.trace("ORMap \(id) deleted")
                ownerEventProbe.tell(.ownerDefinedOnDelete)
            }

            return .receiveMessage { message in
                switch message {
                case .increment(let key, let amount, let consistency, let timeout, let replyTo):
                    m.update(key: key, writeConsistency: consistency, timeout: timeout) {
                        $0.increment(by: amount)
                    }._onComplete { result in
                        switch result {
                        case .success(let m):
                            replyTo.tell(m.underlying)
                        case .failure(let error):
                            fatalError("increment error \(error)")
                        }
                    }
                case .removeValue(let key, let consistency, let timeout, let replyTo):
                    m.unsafeRemoveValue(forKey: key, writeConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let m):
                            replyTo.tell(m.underlying)
                        case .failure(let error):
                            fatalError("removeValue error \(error)")
                        }
                    }
                case .read(let consistency, let timeout, let replyTo):
                    m.read(atConsistency: consistency, timeout: timeout)._onComplete { result in
                        switch result {
                        case .success(let m):
                            replyTo.tell(m.underlying)
                        case .failure(let error):
                            fatalError("read error \(error)")
                        }
                    }
                case .lastObservedValue(let replyTo):
                    replyTo.tell(m.lastObservedValue)
                }
                return .same
            }
        }
    }

    func test_actorOwned_ORMap_update_shouldNotifyOthers() throws {
        let m1 = "ormap-1"
        let m2 = "ormap-2"

        // m1 has two owners
        let m1Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let m1Owner1 = try system.spawn("ormap1-owner1", self.actorOwnedORMapBehavior(id: m1, oep: m1Owner1EventP.ref))
        let m1Owner1GCounterDictP = self.testKit.spawnTestProbe(expecting: [String: CRDT.GCounter].self)

        let m1Owner2EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let m1Owner2 = try system.spawn("ormap1-owner2", self.actorOwnedORMapBehavior(id: m1, oep: m1Owner2EventP.ref))
        let m1Owner2GCounterDictP = self.testKit.spawnTestProbe(expecting: [String: CRDT.GCounter].self)

        // m2 has one owner
        let m2Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let m2Owner1 = try system.spawn("ormap2-owner1", self.actorOwnedORMapBehavior(id: m2, oep: m2Owner1EventP.ref))
        let m2Owner1GCounterDictP = self.testKit.spawnTestProbe(expecting: [String: CRDT.GCounter].self)

        // m1 not modified yet
        m1Owner1.tell(.lastObservedValue(replyTo: m1Owner1GCounterDictP.ref))
        let m1o1 = try m1Owner1GCounterDictP.expectMessage()
        m1o1.isEmpty.shouldBeTrue()

        // Add key-value to m1 and the latest value should be returned
        m1Owner1.tell(.increment(key: "g1", amount: 3, consistency: .local, timeout: .milliseconds(100), replyTo: m1Owner1GCounterDictP.ref))
        let m1oo1 = try m1Owner1GCounterDictP.expectMessage()
        m1oo1.count.shouldEqual(1)
        guard let g1 = m1oo1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1oo1)")
        }
        g1.value.shouldEqual(3)

        // m1 owner1's local value should be up-to-date
        m1Owner1.tell(.lastObservedValue(replyTo: m1Owner1GCounterDictP.ref))
        let m1ooo1 = try m1Owner1GCounterDictP.expectMessage()
        m1ooo1.count.shouldEqual(1)
        guard let gg1 = m1ooo1["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1ooo1)")
        }
        gg1.value.shouldEqual(3)

        // owner1 should be notified even if it triggered the action
        try m1Owner1EventP.expectMessage(.ownerDefinedOnUpdate)

        // owner2 should be notified about m1 updates, which means it should have up-to-date value too
        try m1Owner2EventP.expectMessage(.ownerDefinedOnUpdate)
        m1Owner2.tell(.lastObservedValue(replyTo: m1Owner2GCounterDictP.ref))
        let m1o2 = try m1Owner2GCounterDictP.expectMessage()
        m1o2.count.shouldEqual(1)
        guard let ggg1 = m1o2["g1"] else {
            throw shouldNotHappen("Expect m1 to contain \"g1\", got \(m1o2)")
        }
        ggg1.value.shouldEqual(3)

        // m2 hasn't been mutated
        m2Owner1.tell(.read(consistency: .local, timeout: .milliseconds(100), replyTo: m2Owner1GCounterDictP.ref))
        let m2o1 = try m2Owner1GCounterDictP.expectMessage()
        m2o1.isEmpty.shouldBeTrue()
        // As a result owner should not have received any events
        try m2Owner1EventP.expectNoMessage(for: .milliseconds(100))
    }
}
