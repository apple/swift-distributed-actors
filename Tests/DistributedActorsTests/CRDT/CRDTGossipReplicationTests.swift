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
    var localSystem: ActorSystem!
    var localTestKit: ActorTestKit!

    var remoteSystem: ActorSystem!
    var remoteTestKit: ActorTestKit!

    func setUpLocal() {
        self.localSystem = super.setUpNode("local")
        self.localTestKit = super.testKit(self.localSystem)
    }

    func setUpRemote() {
        self.remoteSystem = super.setUpNode("remote")
        self.remoteTestKit = super.testKit(self.remoteSystem)
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .wellKnown)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .wellKnown)

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
