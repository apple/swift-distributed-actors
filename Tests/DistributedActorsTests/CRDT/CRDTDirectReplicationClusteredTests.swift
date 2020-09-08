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

final class CRDTDirectReplicationTests: ClusteredActorSystemsXCTestCase {
    var localSystem: ActorSystem!
    var localTestKit: ActorTestKit!

    var remoteSystem: ActorSystem!
    var remoteTestKit: ActorTestKit!

    override func setUp() {
        self.localSystem = super.setUpNode("local")
        self.localTestKit = super.testKit(self.localSystem)

        self.remoteSystem = super.setUpNode("remote")
        self.remoteTestKit = super.testKit(self.remoteSystem)
    }

    lazy var ownerAlpha = try! ActorAddress(local: localSystem.cluster.uniqueNode, path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)
    lazy var ownerBeta = try! ActorAddress(local: localSystem.cluster.uniqueNode, path: ActorPath._user.appending("beta"), incarnation: .wellKnown)

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

    func test_directReplication_whenNoPeers() throws {
        let p: ActorTestProbe<String> = self.localTestKit.spawnTestProbe(expecting: String.self)

        _ = try self.localSystem.spawn("owner", of: String.self, .setup { context in
            let set: CRDT.ActorOwned<CRDT.ORSet<Int>> = CRDT.ORSet.makeOwned(by: context, id: "s1")
            let adding: CRDT.OperationResult<CRDT.ORSet<Int>> = set.insert(1, writeConsistency: .quorum, timeout: .effectivelyInfinite)
            adding.onComplete { result in
                p.tell("\(result)")
            }
            return .receiveMessage { _ in .same }
        })

        try p.expectMessage().shouldContain("\(DistributedActors.CRDT.OperationConsistency.Error.remoteReplicasRequired)")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Test utilities

    private func makeCRDTOwnerTestProbe(system: ActorSystem, testKit: ActorTestKit, id: CRDT.Identity, data: StateBasedCRDT) throws -> ActorTestProbe<OwnerMessage> {
        let ownerP = testKit.spawnTestProbe(expecting: OwnerMessage.self)
        let registerP = testKit.spawnTestProbe(expecting: LocalRegisterResult.self)

        // Register owner so replicator will notify it on CRDT updates
        system.replicator.tell(.localCommand(.register(ownerRef: ownerP.ref, id: id, data: data, replyTo: registerP.ref)))
        guard case .success = try registerP.expectMessage() else { throw registerP.error() }

        return ownerP
    }
}
