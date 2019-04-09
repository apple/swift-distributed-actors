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

class FailureDetectorTests: XCTestCase {

    var local: ActorSystem! = nil

    var remote: ActorSystem! = nil

    lazy var localUniqueAddress: UniqueNodeAddress = self.local.settings.cluster.uniqueBindAddress
    lazy var remoteUniqueAddress: UniqueNodeAddress = self.remote.settings.cluster.uniqueBindAddress

    override func setUp() {
        self.local = ActorSystem("FailureDetectorTests") { settings in
            settings.cluster.failureDetector = .manual

            settings.cluster.enabled = true
            settings.cluster.bindAddress.port =  7337
        }
        self.remote = ActorSystem("FailureDetectorTests") { settings in
            settings.cluster.failureDetector = .manual

            settings.cluster.enabled = true
            settings.cluster.bindAddress.port = 8228
        }
    }

    override func tearDown() {
        self.local.shutdown()
        self.remote.shutdown()
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: ManualFailureDetector tests

    func joinNodes() throws {
        local.clusterShell.tell(.command(.handshakeWith(remoteUniqueAddress.address))) // TODO nicer API
        sleep(1) // FIXME make sure assertions work well without any sleeps
        try assertAssociated(system: local, expectAssociatedAddress: remoteUniqueAddress)
        try assertAssociated(system: remote, expectAssociatedAddress: localUniqueAddress)
    }

    func test_manualFailureDetector_shouldFailAllRefsOnSpecificAddress() throws {
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

        let ref: ActorRef<String> = try local.spawn(.setup { context in
            context.watch(remote1)
            context.watch(remote2)

            let recv: Behavior<String> = .receiveMessage { message in
                return .same
            }

            return recv.receiveSignal { context, signal in
                switch signal {
                case let terminated as Signals.Terminated:
                    p.ref.tell(terminated)
                default:
                    break
                }
                return .same
            }
        }, name: "local")

        // --- manually trigger failure detector for remote address ---

        let failureDetector: FailureDetectorShell.Ref = try getLocalFailureDetector(p: p)

        // FIXME: this should be done automatically upon association
        let localMember = Member(address: self.localUniqueAddress, status: .alive)
        let remoteMember = Member(address: self.remoteUniqueAddress, status: .alive)
        failureDetector.tell(.membershipSnapshot([localMember, remoteMember])) // join all members

        // down the remote node
        let downRemoteChange = MembershipChange(address: self.remoteUniqueAddress, fromStatus: MemberStatus.alive, toStatus: MemberStatus.down)
        failureDetector.tell(.membershipChange(downRemoteChange))

        // --- should cause termination of all remote actors, observed by the local actor ---
        let terminations: [Signals.Terminated] = try p.expectMessages(count: 2)
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.path.name == "remote-1"
        })
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.path.name == "remote-2"
        })

        // should not trigger terminated again for any of the remote refs
        // (for many reasons, the node already is marked terminated, the actors have already have Terminated sent for them etc)
        failureDetector.tell(.membershipChange(downRemoteChange))
        try p.expectNoMessage(for: .milliseconds(100))
    }


    private func getLocalFailureDetector(p: ActorTestProbe<Signals.Terminated>) throws -> FailureDetectorShell.Ref {
        guard let failureDetector = local._remoting?._failureDetectorRef else {
            throw p.error("Failure detector MUST be available")
        }

        return failureDetector
    }
}
