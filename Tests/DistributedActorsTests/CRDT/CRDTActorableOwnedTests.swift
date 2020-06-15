//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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
import NIO
import XCTest

// FIXME: de-duplicate with CRDTActorOwnedTests? replicating all tests here is a bit annoying as they test the same but in diff API
final class CRDTActorableOwnedTests: ActorSystemTestBase {
    func test_actorOwned_GCounter_increment_shouldNotifyOthers() throws {
        let g1 = "gcounter-1"
        let g2 = "gcounter-2"

        // g1 has two owners
        let g1Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner1 = try system.spawn("gcounter1-owner1") { context in
            TestGCounterOwner(context: context, id: g1, oep: g1Owner1EventP.ref)
        }

        let g1Owner2EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g1Owner2 = try system.spawn("gcounter1-owner2") { context in
            TestGCounterOwner(context: context, id: g1, oep: g1Owner2EventP.ref)
        }

        // g2 has one owner
        let g2Owner1EventP = self.testKit.spawnTestProbe(expecting: OwnerEventProbeMessage.self)
        let g2Owner1 = try system.spawn("gcounter2-owner1") { context in
            TestGCounterOwner(context: context, id: g2, oep: g2Owner1EventP.ref)
        }

        // g1 not incremented yet
        try testKit.expect(g1Owner1.lastObservedValue(), 0)

        // Increment g1 and the latest value should be returned
        try testKit.expect(g1Owner1.increment(amount: 3, consistency: .local, timeout: .milliseconds(100)), 3)

        // g1 owner1's local value should be up-to-date
        try testKit.expect(g1Owner1.lastObservedValue(), 3)

        // owner1 should be notified even if it triggered the action
        try g1Owner1EventP.expectMessage(.ownerDefinedOnUpdate)

        // owner2 should be notified about g1 updates, which means it should have up-to-date value too
        try g1Owner2EventP.expectMessage(.ownerDefinedOnUpdate)
        try testKit.expect(g1Owner2.lastObservedValue(), 3)

        // g2 hasn't been mutated
        try testKit.expect(g2Owner1.read(consistency: .local, timeout: .milliseconds(100)), 0)
        // As a result owner should not have received any events
        try g2Owner1EventP.expectNoMessage(for: .milliseconds(100))
    }
}

// FIXME: make this be inside the owner; https://github.com/apple/swift-distributed-actors/issues/404
enum OwnerEventProbeMessage: String, ActorMessage {
    case ownerDefinedOnUpdate
    case ownerDefinedOnDelete
}

struct TestGCounterOwner: Actorable {
    let context: Myself.Context
    let counter: CRDT.ActorableOwned<CRDT.GCounter>

    let ownerEventProbe: ActorRef<OwnerEventProbeMessage>

    init(context: Myself.Context, id: String, oep ownerEventProbe: ActorRef<OwnerEventProbeMessage>) {
        self.context = context
        self.counter = CRDT.GCounter.makeOwned(by: context, id: id)
        self.ownerEventProbe = ownerEventProbe
    }

    // @actor
    func preStart(context: Myself.Context) {
        self.counter.onUpdate { id, gg in
            context.log.trace("GCounter \(id) updated with new value: \(gg.value)")
            self.ownerEventProbe.tell(.ownerDefinedOnUpdate)
        }
        self.counter.onDelete { id in
            context.log.trace("GCounter \(id) deleted")
            self.ownerEventProbe.tell(.ownerDefinedOnDelete)
        }
    }

    // @actor
    func increment(amount: Int, consistency: CRDT.OperationConsistency, timeout: DistributedActors.TimeAmount) -> Int {
        _ = self.counter.increment(by: amount, writeConsistency: consistency, timeout: timeout)
        return self.lastObservedValue()
    }

    // @actor
    func read(consistency: CRDT.OperationConsistency, timeout: DistributedActors.TimeAmount) -> EventLoopFuture<Int> {
        let p = self.context.system._eventLoopGroup.next().makePromise(of: Int.self)
        self.counter.read(atConsistency: consistency, timeout: timeout).onComplete {
            switch $0 {
            case .success(let updatedCounter):
                p.succeed(updatedCounter.value)
            case .failure(let error):
                p.fail(error)
            }
        }
        return p.futureResult
    }

    // @actor
    func lastObservedValue() -> Int {
        self.counter.lastObservedValue
    }
}
