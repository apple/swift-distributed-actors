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
        let ownerEventPa = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let ownerEventPb = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)

        let behavior: Behavior<String> = .setup { context in
            let g = CRDT.GCounter.owned(by: context, id: "test-gcounter")
            g.onUpdate { _, _ in
                ownerEventPa.tell(.ownerDefinedOnUpdate)
            }
            // Overwrites the callback above
            g.onUpdate { _, _ in
                ownerEventPb.tell(.ownerDefinedOnUpdate)
            }

            return .receiveMessage { _ in
                _ = g.increment(by: 1, writeConsistency: .local, timeout: .milliseconds(100))
                return .same
            }
        }
        let a = try system.spawnAnonymous(behavior)

        a.tell("hello")
        // This callback was overwritten so it shouldn't be invoked
        try ownerEventPa.expectNoMessage(for: .milliseconds(100))
        // The "winner"
        try ownerEventPb.expectMessage(.ownerDefinedOnUpdate)
    }

    func test_actorOwnedGCounter_shouldBeIncremented_shouldResetDelta_shouldNotifyOthers() throws {
        let g1 = "gcounter-1"
        let g2 = "gcounter-2"

        // a1 and a2 own g1
        let a1OwnerEventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let a1 = try system.spawn(actorOwnedGCounterBehavior(id: g1, oep: a1OwnerEventP.ref), name: "GCounterTestActor1")
        let a1P = testKit.spawnTestProbe(expecting: Int.self)
        let a1HasDeltaP = testKit.spawnTestProbe(expecting: Bool.self)

        let a2OwnerEventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let a2 = try system.spawn(actorOwnedGCounterBehavior(id: g1, oep: a2OwnerEventP.ref), name: "GCounterTestActor2")
        let a2P = testKit.spawnTestProbe(expecting: Int.self)

        // a3 owns g2
        let a3OwnerEventP = testKit.spawnTestProbe(expecting: OwnerEventProbeProtocol.self)
        let a3 = try system.spawn(actorOwnedGCounterBehavior(id: g2, oep: a3OwnerEventP.ref), name: "GCounterTestActor3")
        let a3P = testKit.spawnTestProbe(expecting: Int.self)

        // g1 not incremented yet
        a1.tell(.lastObservedValue(replyTo: a1P.ref))
        try a1P.expectMessage(0)

        // Implement g1 and the latest value should be returned
        a1.tell(.increment(amount: 3, consistency: .local, timeout: .milliseconds(100), replyTo: a1P.ref))
        try a1P.expectMessage(3)

        // a1's local g1 value should be up-to-date
        a1.tell(.lastObservedValue(replyTo: a1P.ref))
        try a1P.expectMessage(3)

        // a1's g1.delta should be reset
        a1.tell(.hasDelta(replyTo: a1HasDeltaP.ref))
        try a1HasDeltaP.expectMessage(false)

        // a1 should receive events about g1 updates even if it triggered the action
        try a1OwnerEventP.expectMessage(.ownerDefinedOnUpdate)

        // a2 should receive events about g1 updates, which means it should have up-to-date value too
        try a2OwnerEventP.expectMessage(.ownerDefinedOnUpdate)
        a2.tell(.lastObservedValue(replyTo: a2P.ref))
        try a2P.expectMessage(3)

        // g2 hasn't been mutated
        a3.tell(.read(consistency: .local, timeout: .milliseconds(100), replyTo: a3P.ref))
        try a3P.expectMessage(0)
        // As a result a3 should not have received any events yet
        try a3OwnerEventP.expectNoMessage(for: .milliseconds(100))
    }
}
