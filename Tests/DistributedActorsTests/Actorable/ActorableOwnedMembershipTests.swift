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

final class ActorableOwnedMembershipTests: ClusteredNodesTestBase {
    func test_autoUpdatedMembership_updatesAutomatically() throws {
        try shouldNotThrow {
            let first = self.setUpNode("first") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }
            let second = self.setUpNode("second") { settings in
                settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            }

            let p = self.testKit(first).spawnTestProbe(expecting: Membership.self)
            let owner = try first.spawn("membershipOwner") {
                TestMembershipOwner(context: $0, probe: p.ref)
            }

            // FIXME: this should work even if we call join nodes EAGERLY

            try self.joinNodes(node: first, with: second, ensureMembers: .up)
            try self.assertMemberStatus(on: first, node: second.cluster.node, is: .up)

            try self.testKit(first).eventually(within: .seconds(3)) {
                let membershipReply = owner.replyMembership()
                let membership = try membershipReply._nioFuture.wait()
                guard membership?.count(atLeast: .joining) == 2 else {
                    throw Boom("Not yet all joining nodes in lastObservedValue")
                }
            }
        }
    }
}

struct TestMembershipOwner: Actorable {
    let context: Myself.Context
    let membership: ActorableOwned<Membership>

    static var generateCodableConformance: Bool {
        false
    }

    init(context: Myself.Context, probe: ActorRef<Membership>) {
        self.context = context
        self.membership = context.system.cluster.autoUpdatedMembership(context)
        self.membership.onUpdate {
            if $0.members(atLeast: .joining).count > 0 {
                probe.tell($0)
            }
        }
    }

    func replyMembership() -> Membership? {
        self.membership.lastObservedValue
    }
}
