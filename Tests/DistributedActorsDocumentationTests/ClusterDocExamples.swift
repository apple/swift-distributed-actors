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

// tag::imports[]

import DistributedActors

// end::imports[]

@testable import DistributedActorsTestKit
import XCTest

class ClusterDocExamples: XCTestCase {
    func example_receive_behavior() throws {
        // tag::joining[]
        let system = ActorSystem("ClusterJoining") { settings in
            settings.cluster.enabled = true // <1>
            // system will bind by default on `localhost:7337`
        }

        let otherNode = Node(systemName: "ClusterJoining", host: "localhost", port: 8228)
        system.cluster.join(node: otherNode) // <2>

        // end::joining[]
    }

    func example_subscribe_events_apply() throws {
        let system = ActorSystem("Sample")

        try system.spawn(
            .anonymous,
            of: String.self,
            .setup { context in
                // tag::subscribe-events-apply-general[]
                var membership: Cluster.Membership = .empty // <1>

                let subRef = context.subReceive(Cluster.Event.self) { event in // <2>
                    try membership.apply(event: event) // <3>
                    context.log.info("The most up to date membership is: \(membership)")
                }

                context.system.cluster.events.subscribe(subRef) // <4>
                // end::subscribe-events-apply-general[]
                return .same
            }
        )

        // tag::membership-snapshot[]
        let snapshot: Cluster.Membership = system.cluster.membershipSnapshot
        // end::membership-snapshot[]
        _ = snapshot // silence not-used warning
    }
}
