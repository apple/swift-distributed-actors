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
import SWIM
import XCTest

/// Tests of the SWIM.Instance which require the existence of actor systems, even if the instance tests are driven manually.
final class SWIMInstanceClusteredTests: ClusteredActorSystemsXCTestCase {
    let testNode = UniqueNode(systemName: "test", host: "test", port: 12345, nid: UniqueNodeID(1111))

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
}
