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
import XCTest

final class ActorableOwnedMembershipTests: ClusteredActorSystemsXCTestCase {
    func test_autoUpdatedMembership_updatesAutomatically() throws {
        let first = self.setUpNode("first") { settings in
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
        }
        let second = self.setUpNode("second") { settings in
            settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
        }

        try self.joinNodes(node: first, with: second, ensureMembers: .up)
        try self.assertMemberStatus(on: first, node: second.cluster.uniqueNode, is: .up)

        let owner = try first.spawn("membershipOwner") {
            TestMembershipOwner(context: $0)
        }

        try self.testKit(first).eventually(within: .seconds(3)) {
            let membershipReply = owner.replyMembership()
            let membership = try membershipReply.wait()
            guard membership?.count(atLeast: .up) == 2 else {
                throw Boom("Not yet all joining nodes in lastObservedValue, was: \(reflecting: membership)")
            }
        }
    }

    func test_notCrashHard_whenCall_onShutDownSystem() throws {
        let p = self.testKit.spawnTestProbe(expecting: Reception.Listing<Actor<OwnerOfThings>>.self)
        let owner: Actor<OwnerOfThings> = try self.system.spawn("owner") {
            OwnerOfThings(context: $0, probe: p.ref)
        }

        try self.system.shutdown().wait()
        let x = owner.readLastObservedValue()
        do {
            let reply = try x.wait()
            XCTFail("Expected call to throw, but got: \(reply)")
        } catch {
            "\(error)".shouldContain("DistributedActors.AskError")
        }
    }
}

struct TestMembershipOwner: Actorable {
    let context: Myself.Context
    let membership: ActorableOwned<Cluster.Membership>

    init(context: Myself.Context) {
        self.context = context
        self.membership = context.system.cluster.autoUpdatedMembership(context)
    }

    // @actor
    func replyMembership() -> Cluster.Membership? {
        self.membership.lastObservedValue
    }
}
