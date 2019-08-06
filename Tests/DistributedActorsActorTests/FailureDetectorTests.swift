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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class FailureDetectorTests: ClusteredTwoNodesTestBase {

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: ManualFailureDetector tests

    func test_manualFailureDetector_shouldFailAllRefsOnSpecificAddress() throws {
        self.setUpBoth()
        try self.joinNodes()

        // TODO: if we had a receptionist, use it here to get those refs

        let localOnRemote1: ActorRef<String> = try remote.spawn(.ignore, name: "remote-1")
        let remote1 = local._resolve(ref: localOnRemote1, onSystem: remote)
        let localOnRemote2: ActorRef<String> = try remote.spawn(.ignore, name: "remote-2")
        let remote2 = local._resolve(ref: localOnRemote2, onSystem: remote)

        // https://github.com/apple/swift-distributed-actors/issues/458
        let testKit = ActorTestKit(local)
        let p = testKit.spawnTestProbe(name: "p", expecting: Signals.Terminated.self) // TODO: has to carry explicit name since https://github.com/apple/swift-distributed-actors/issues/458

        // --- prepare actor on local, which watches remote actors ---

        _ = try local.spawn(Behavior<String>.setup { context in
            context.watch(remote1)
            context.watch(remote2)

            let recv: Behavior<String> = .receiveMessage { message in
                return .same
            }

            return recv.receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                p.ref.tell(terminated)
                return .same
            }
        }, name: "local")

        // --- manually trigger failure detector for remote node ---

        let failureDetector: FailureDetectorShell.Ref = try getLocalFailureDetector(p: p)

        // FIXME: this should be done automatically upon association
        let localMember = Member(node: self.localUniqueNode, status: .alive)
        let remoteMember = Member(node: self.remoteUniqueNode, status: .alive)
        failureDetector.tell(.membershipSnapshot([localMember, remoteMember])) // join all members

        // down the remote node
        let downRemoteChange = MembershipChange(node: self.remoteUniqueNode, fromStatus: MemberStatus.alive, toStatus: MemberStatus.down)
        failureDetector.tell(.membershipChange(downRemoteChange))

        // --- should cause termination of all remote actors, observed by the local actor ---
        let terminations: [Signals.Terminated] = try p.expectMessages(count: 2)
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.address.name == "remote-1"
        })
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.address.name == "remote-2"
        })

        // should not trigger terminated again for any of the remote refs
        // (for many reasons, the node already is marked terminated, the actors have already have Terminated sent for them etc)
        failureDetector.tell(.membershipChange(downRemoteChange))
        try p.expectNoMessage(for: .milliseconds(100))
    }


    private func getLocalFailureDetector(p: ActorTestProbe<Signals.Terminated>) throws -> FailureDetectorShell.Ref {
        guard let failureDetector = local._cluster?._failureDetectorRef else {
            throw p.error("Failure detector MUST be available")
        }

        return failureDetector
    }
}
