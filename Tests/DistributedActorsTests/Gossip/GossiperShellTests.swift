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

final class GossiperShellTests: ActorSystemXCTestCase {
    func peerBehavior<T: Codable>() -> Behavior<GossipShell<T, String>.Message> {
        .receiveMessage { msg in
            if "\(msg)".contains("stop") { return .stop } else { return .same }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: test_down_beGossipedToOtherNodes

    func test_down_beGossipedToOtherNodes() throws {
        let p = self.testKit.spawnTestProbe(expecting: [AddressableActorRef].self)

        let control = try Gossiper._spawn
            self.system,
            name: "gossiper",
            settings: .init(
                interval: .seconds(1),
                style: .unidirectional
            )
        ) { _ in InspectOfferedPeersTestGossipLogic(offeredPeersProbe: p.ref) }

        let first: _ActorRef<GossipShell<InspectOfferedPeersTestGossipLogic.Gossip, String>.Message> =
            try self.system._spawn("first", self.peerBehavior())
        let second: _ActorRef<GossipShell<InspectOfferedPeersTestGossipLogic.Gossip, String>.Message> =
            try self.system._spawn("second", self.peerBehavior())

        control.introduce(peer: first)
        control.introduce(peer: second)
        control.update(StringGossipIdentifier("hi"), payload: .init("hello"))

        try Set(p.expectMessage()).shouldEqual(Set([first.asAddressable, second.asAddressable]))

        first.tell(.removePayload(identifier: StringGossipIdentifier("stop")))
        try Set(p.expectMessage()).shouldEqual(Set([second.asAddressable]))

        first.tell(.removePayload(identifier: StringGossipIdentifier("stop")))
        try p.expectNoMessage(for: .milliseconds(300))
    }

    struct InspectOfferedPeersTestGossipLogic: GossipLogic {
        struct Gossip: Codable {
            let metadata: String
            let payload: String

            init(_ info: String) {
                self.metadata = info
                self.payload = info
            }
        }

        typealias Acknowledgement = String

        let offeredPeersProbe: _ActorRef<[AddressableActorRef]>
        init(offeredPeersProbe: _ActorRef<[AddressableActorRef]>) {
            self.offeredPeersProbe = offeredPeersProbe
        }

        func selectPeers(_ peers: [AddressableActorRef]) -> [AddressableActorRef] {
            self.offeredPeersProbe.tell(peers)
            return []
        }

        func makePayload(target: AddressableActorRef) -> Gossip? {
            nil
        }

        func receiveAcknowledgement(_ acknowledgement: Acknowledgement, from peer: AddressableActorRef, confirming gossip: Gossip) {}

        func receiveGossip(_ gossip: Gossip, from peer: AddressableActorRef) -> Acknowledgement? {
            nil
        }

        func receiveLocalGossipUpdate(_ gossip: Gossip) {}
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: test_unidirectional_yetEmitsAck_shouldWarn

    func test_unidirectional_yetReceivesAckRef_shouldWarn() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let control = try Gossiper._spawn
            self.system,
            name: "noAcks",
            settings: .init(
                interval: .milliseconds(100),
                style: .unidirectional
            ),
            makeLogic: { _ in NoAcksTestGossipLogic(probe: p.ref) }
        )

        let first: _ActorRef<GossipShell<NoAcksTestGossipLogic.Gossip, NoAcksTestGossipLogic.Acknowledgement>.Message> =
            try self.system._spawn("first", self.peerBehavior())

        control.introduce(peer: first)
        control.update(StringGossipIdentifier("hi"), payload: .init("hello"))
        control.ref.tell(
            .gossip(
                identity: StringGossipIdentifier("example"),
                origin: first, .init("unexpected"),
                ackRef: system.deadLetters.adapted() // this is wrong on purpose; we're configured as `unidirectional`; this should cause warnings
            )
        )

        try self.logCapture.awaitLogContaining(
            self.testKit,
            text: " Incoming gossip has acknowledgement actor ref and seems to be expecting an ACK, while this gossiper is configured as .unidirectional!"
        )
    }

    struct NoAcksTestGossipLogic: GossipLogic {
        struct Gossip: Codable {
            let metadata: String
            let payload: String

            init(_ info: String) {
                self.metadata = info
                self.payload = info
            }
        }

        let probe: _ActorRef<String>

        typealias Acknowledgement = String

        func selectPeers(_ peers: [AddressableActorRef]) -> [AddressableActorRef] {
            peers
        }

        func makePayload(target: AddressableActorRef) -> Gossip? {
            .init("Hello") // legal but will produce a warning
        }

        func receiveAcknowledgement(_ acknowledgement: Acknowledgement, from peer: AddressableActorRef, confirming gossip: Gossip) {
            self.probe.tell("un-expected acknowledgement: \(acknowledgement) from \(peer) confirming \(gossip)")
        }

        func receiveGossip(_ gossip: Gossip, from peer: AddressableActorRef) -> Acknowledgement? {
            nil
        }

        func receiveLocalGossipUpdate(_ gossip: Gossip) {}
    }
}
