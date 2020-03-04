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

final class CRDTGossipReplicationTests: ClusteredNodesTestBase {

    var firstSystem: ActorSystem!
    var secondSystem: ActorSystem!
    var thirdSystem: ActorSystem!
    var fourthSystem: ActorSystem!
    var fifthSystem: ActorSystem!

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster",
            "/system/cluster/swim",
            "/system/clusterEvents",
            "/system/cluster/gossip",
            "/system/cluster/leadership",
            "/system/transport.server",
            "/system/transport.client",
        ]

    }

    override func setUp() {
        self.firstSystem = super.setUpNode("first")
        self.secondSystem = super.setUpNode("second")
//        self.thirdSystem = super.setUpNode("third")
//        self.fourthSystem = super.setUpNode("fourth")
//        self.fifthSystem = super.setUpNode("fifth")

        self.firstSystem.cluster.join(node: self.secondSystem.cluster.node)
//        self.firstSystem.cluster.join(node: self.thirdSystem.cluster.node)
//        self.firstSystem.cluster.join(node: self.fourthSystem.cluster.node)
//        self.firstSystem.cluster.join(node: self.fifthSystem.cluster.node)
    }

    lazy var ownerFirstOne = try! ActorAddress(path: ActorPath._user.appending("first-1"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.firstSystem.cluster.node)
    lazy var ownerFirstTwo = try! ActorAddress(path: ActorPath._user.appending("first-2"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.firstSystem.cluster.node)

    lazy var ownerSecondOne = try! ActorAddress(path: ActorPath._user.appending("second-1"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.secondSystem.cluster.node)

    lazy var ownerThirdOne = try! ActorAddress(path: ActorPath._user.appending("third-1"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.thirdSystem.cluster.node)

    lazy var ownerFourthOne = try! ActorAddress(path: ActorPath._user.appending("fourth-1"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.fourthSystem.cluster.node)

    lazy var ownerFifthOne = try! ActorAddress(path: ActorPath._user.appending("fifth-1"), incarnation: .wellKnown)
        .fillNodeWhenEmpty(self.fifthSystem.cluster.node)

    let timeout = TimeAmount.seconds(1)

    typealias OwnerMessage = CRDT.Replication.DataOwnerMessage
    typealias Message = CRDT.Replicator.Message
    typealias LocalRegisterResult = CRDT.Replicator.LocalCommand.RegisterResult
    typealias LocalWriteResult = CRDT.Replicator.LocalCommand.WriteResult
    typealias LocalReadResult = CRDT.Replicator.LocalCommand.ReadResult
    typealias LocalDeleteResult = CRDT.Replicator.LocalCommand.DeleteResult
    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    typealias RemoteReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    typealias RemoteDeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult
    typealias OperationExecution = CRDT.Replicator.OperationExecution


    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Replication Tests

    func test_gossipReplicate_gCounter() throws {
        let id = CRDT.Identity("gcounter-1")

        _ = try self.firstSystem.spawn("owner", of: Never.self, .setup { context in
            // TODO: context.makeCRDT("my-counter", CRDT.GCounter.self) ???
            let owned = CRDT.ActorOwned(ownerContext: context, id: id, data: CRDT.GCounter(replicaId: .actorAddress(self.ownerFirstOne)))
            _ = owned.increment(by: 1, writeConsistency: .local, timeout: .seconds(1))

            return .receiveMessage { _ in .same }
        })

        // ==== ---------------------------------------------------------
        // Expectations

        let p2 = try self.makeCRDTOwnerTestProbe(system: self.secondSystem, testKit: self.testKit(self.secondSystem),
            id: id, data: CRDT.GCounter(replicaId: .actorAddress(self.ownerSecondOne)).asAnyStateBasedCRDT
        )
        let m1 = try p2.expectMessage()
        pprint("m1 = \(m1)")

    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Test utilities

    private func makeCRDTOwnerTestProbe(system: ActorSystem, testKit: ActorTestKit, id: CRDT.Identity, data: AnyStateBasedCRDT) throws -> ActorTestProbe<OwnerMessage> {
        let ownerP = testKit.spawnTestProbe(expecting: OwnerMessage.self)
        let registerP = testKit.spawnTestProbe(expecting: LocalRegisterResult.self)

        // Register owner so replicator will notify it on CRDT updates
        system.replicator.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: data, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else {
            throw registerP.error()
        }

        return ownerP
    }
}
