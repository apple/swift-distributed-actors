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
import XCTest

/// Tests of the SWIM.Instance which require the existence of actor systems, even if the instance tests are driven manually.
final class SWIMInstanceClusteredTests: ClusteredNodesTestBase {
    var localClusterProbe: ActorTestProbe<ClusterShell.Message>!
    var remoteClusterProbe: ActorTestProbe<ClusterShell.Message>!

    func setUpLocal(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let local = super.setUpNode("local", modifySettings)
        self.localClusterProbe = self.testKit(local).spawnTestProbe()
        return local
    }

    func setUpRemote(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let remote = super.setUpNode("remote", modifySettings)
        self.remoteClusterProbe = self.testKit(remote).spawnTestProbe()
        return remote
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling gossip about the receiving node

    func test_swim_cluster_onGossipPayload_newMember_needsToConnect_successfully() throws {
        // we do not really cluster up the nodes, but need their existence to drive our swim interactions
        let local = self.setUpLocal()
        let remote = self.setUpRemote()

        let swim = SWIM.Instance(.default)

        let myself = try local.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.localClusterProbe.ref).ready)
        swim.addMyself(myself)
        swim.memberCount.shouldEqual(1)

        let other = try remote.spawn("SWIM", SWIM.Shell(SWIM.Instance(.default), clusterRef: self.remoteClusterProbe.ref).ready)
        let remoteShell = local._resolveKnownRemote(other, onRemoteSystem: remote)
        let remoteMember = SWIM.Member(ref: remoteShell, status: .alive(incarnation: 0), protocolPeriod: 0)

        let res = swim.onGossipPayload(about: remoteMember)

        switch res {
        case .connect(_, let onceConnected):
            swim.memberCount.shouldEqual(1) // the new member should not yet be added until we can confirm we are able to connect

            // we act as if we connected successfully
            onceConnected(remote.settings.cluster.uniqueBindNode)

            swim.memberCount.shouldEqual(2) // successfully joined
            swim.member(for: remoteShell)!.status.shouldEqual(remoteMember.status)

        default:
            throw self.testKit(local).fail("Should have requested connecting to the new node")
        }
    }

    func test_swim_cluster_onGossipPayload_newMember_needsToConnect_andFails_shouldNotAddMember() throws {
        // we do not really cluster up the nodes, but need their existence to drive our swim interactions
        let local = self.setUpLocal()
        let remote = self.setUpRemote()

        let swim = SWIM.Instance(.default)

        let myself = try local.spawn("SWIM", SWIM.Shell(swim, clusterRef: self.localClusterProbe.ref).ready)
        swim.addMyself(myself)
        _ = swim.member(for: myself)!
        swim.memberCount.shouldEqual(1)

        let other = try remote.spawn("SWIM", SWIM.Shell(SWIM.Instance(.default), clusterRef: self.remoteClusterProbe.ref).ready)
        let remoteShell = local._resolveKnownRemote(other, onRemoteSystem: remote)
        let remoteMember = SWIM.Member(ref: remoteShell, status: .alive(incarnation: 0), protocolPeriod: 0)

        let res = swim.onGossipPayload(about: remoteMember)

        switch res {
        case .connect:
            // and we never trigger onceConnected ... thus the member is never added
            swim.memberCount.shouldEqual(1)

        default:
            throw self.testKit(local).fail("Should have requested connecting to the new node")
        }
    }
}
