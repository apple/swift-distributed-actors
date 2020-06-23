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
import Foundation
import NIOSSL
import XCTest

final class GossipShellTests: ActorSystemXCTestCase {
    func test_down_beGossipedToOtherNodes() throws {
        let p = self.testKit.spawnTestProbe(expecting: [AddressableActorRef].self)

        let control = try Gossiper.start(
            self.system,
            name: "gossiper",
            settings: .init(gossipInterval: .seconds(1)),
            makeLogic: { _ in InspectOfferedPeersTestGossipLogic(offeredPeersProbe: p.ref) }
        )

        let peerBehavior: Behavior<GossipShell<InspectOfferedPeersTestGossipLogic.Envelope, String>.Message> = .receiveMessage { msg in
            if "\(msg)".contains("stop") { return .stop } else { return .same }
        }
        let first = try self.system.spawn("first", peerBehavior)
        let second = try self.system.spawn("second", peerBehavior)

        control.introduce(peer: first)
        control.introduce(peer: second)
        control.update(StringGossipIdentifier("hi"), payload: .init("hello"))

        try Set(p.expectMessage()).shouldEqual(Set([first.asAddressable(), second.asAddressable()]))

        first.tell(.removePayload(identifier: StringGossipIdentifier("stop")))
        try Set(p.expectMessage()).shouldEqual(Set([second.asAddressable()]))

        first.tell(.removePayload(identifier: StringGossipIdentifier("stop")))
        try p.expectNoMessage(for: .milliseconds(300))
    }

    struct InspectOfferedPeersTestGossipLogic: GossipLogic {
        struct Envelope: GossipEnvelopeProtocol {
            let metadata: String
            let payload: String

            init(_ info: String) {
                self.metadata = info
                self.payload = info
            }
        }

        typealias Acknowledgement = String

        let offeredPeersProbe: ActorRef<[AddressableActorRef]>
        init(offeredPeersProbe: ActorRef<[AddressableActorRef]>) {
            self.offeredPeersProbe = offeredPeersProbe
        }

        func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
            self.offeredPeersProbe.tell(peers)
            return []
        }

        func makePayload(target: AddressableActorRef) -> Envelope? {
            nil
        }

        func receiveAcknowledgement(from peer: AddressableActorRef, acknowledgement: Acknowledgement, confirmsDeliveryOf envelope: Envelope) {}

        func receiveGossip(gossip: Envelope, from peer: AddressableActorRef) -> Acknowledgement? {
            nil
        }

        func localGossipUpdate(gossip: Envelope) {}
    }
}
