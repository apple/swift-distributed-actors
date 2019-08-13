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

import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class CRDTActorOwnedTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    private enum GCounterTestProtocol {
        case increment(amount: Int, consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Int>)
        case read(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Int>)
        case delete(consistency: CRDT.OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<Void>)

        case lastObservedValue(replyTo: ActorRef<Int>)
        case status(replyTo: ActorRef<CRDT.Status>)
        case hasDelta(replyTo: ActorRef<Bool>)
    }

    private enum OwnerEventProbeProtocol {
        case ownerDefinedOnUpdate
        case ownerDefinedOnDelete
    }

    private func actorOwnedGCounterBehavior(id: String, oep ownerEventProbe: ActorRef<OwnerEventProbeProtocol>) -> Behavior<GCounterTestProtocol> {
        return .setup { context in
            let g = CRDT.GCounter.owned(by: context, id: id)
            g.onUpdate { id, gg in
                context.log.info("gcounter \(id) updated with new value: \(gg.value)")
                ownerEventProbe.tell(.ownerDefinedOnUpdate)
            }
            g.onDelete { id in
                context.log.info("gcounter \(id) deleted")
                ownerEventProbe.tell(.ownerDefinedOnDelete)
            }

            return .receiveMessage { message in
                switch message {
                case .increment(let amount, let consistency, let timeout, let replyTo):
                    g.increment(by: amount, writeConsistency: consistency, timeout: timeout).onComplete { result in
                        switch result {
                        case .success(let g):
                            replyTo.tell(g.value)
                        case .failure(let error):
                            fatalError("write error \(error)")
                        }
                    }
                case .read(let consistency, let timeout, let replyTo):
                    g.read(atConsistency: consistency, timeout: timeout).onComplete { result in
                        switch result {
                        case .success(let g):
                            replyTo.tell(g.value)
                        case .failure(let error):
                            fatalError("read error \(error)")
                        }
                    }
                case .delete(let consistency, let timeout, let replyTo):
                    g.deleteFromCluster(consistency: consistency, timeout: timeout).onComplete { result in
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
                case .hasDelta(let replyTo):
                    replyTo.tell(g.data.delta != nil)
                }
                return .same
            }
        }
    }

    func test_actorOwned_theLastWrittenOnUpdateCallbackWins() throws {
        let ownerEventPA = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let ownerEventPB = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)

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
        // This callback was overwritten so it shouldn't be invoked
        try ownerEventPA.expectNoMessage(for: .milliseconds(100))
        // The "winner"
        try ownerEventPB.expectMessage(.ownerDefinedOnUpdate)
    }

    func test_actorOwned_GCounter_increment_shouldResetDelta_shouldNotifyOthers() throws {
        let g1 = "gcounter-1"
        let g2 = "gcounter-2"

        // g1 has two owners
        let g1Owner1EventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let g1Owner1 = try system.spawn("gcounter1-owner1", actorOwnedGCounterBehavior(id: g1, oep: g1Owner1EventP.ref))
        let g1Owner1IntP = testKit.spawnTestProbe(expecting: Int.self)
        let g1Owner1BoolP = testKit.spawnTestProbe(expecting: Bool.self)

        let g1Owner2EventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let g1Owner2 = try system.spawn("gcounter1-owner2", actorOwnedGCounterBehavior(id: g1, oep: g1Owner2EventP.ref))
        let g1Owner2IntP = testKit.spawnTestProbe(expecting: Int.self)

        // g2 has one owner
        let g2Owner1EventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let g2Owner1 = try system.spawn("gcounter2-owner1", actorOwnedGCounterBehavior(id: g2, oep: g2Owner1EventP.ref))
        let g2Owner1IntP = testKit.spawnTestProbe(expecting: Int.self)

        // g1 not incremented yet
        g1Owner1.tell(.lastObservedValue(replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(0)

        // Implement g1 and the latest value should be returned
        g1Owner1.tell(.increment(amount: 3, consistency: .local, timeout: .milliseconds(100), replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(3)

        // g1 owner1's local value should be up-to-date
        g1Owner1.tell(.lastObservedValue(replyTo: g1Owner1IntP.ref))
        try g1Owner1IntP.expectMessage(3)

        // owner1's g1.delta should be reset
        g1Owner1.tell(.hasDelta(replyTo: g1Owner1BoolP.ref))
        try g1Owner1BoolP.expectMessage(false)

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

    func test_actorOwned_GCounter_deleteFromCluster_shouldChangeStatus() throws {
        let g1 = "gcounter-1"

        // g1 has two owners
        let g1Owner1EventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let g1Owner1 = try system.spawn("gcounter1-owner1", actorOwnedGCounterBehavior(id: g1, oep: g1Owner1EventP.ref))
        let g1Owner1VoidP = testKit.spawnTestProbe(expecting: Void.self)
        let g1Owner1StatusP = testKit.spawnTestProbe(expecting: CRDT.Status.self)

        let g1Owner2EventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let g1Owner2 = try system.spawn("gcounter1-owner2", actorOwnedGCounterBehavior(id: g1, oep: g1Owner2EventP.ref))
        let g1Owner2StatusP = testKit.spawnTestProbe(expecting: CRDT.Status.self)

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
}
