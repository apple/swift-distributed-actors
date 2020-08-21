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

import ClusterMembership
import enum Dispatch.DispatchTimeInterval
import SWIM

extension SWIM {
    typealias PeerRef = ActorRef<SWIM.Message>
    typealias Ref = ActorRef<SWIM.Message>

    typealias PingOriginRef = ActorRef<SWIM.PingResponse>
    typealias PingRequestOriginRef = ActorRef<SWIM.PingResponse>

    typealias Shell = SWIMActorShell
}

public protocol AnySWIMMessage {}
extension SWIM.Message: AnySWIMMessage {}
extension SWIM.PingResponse: AnySWIMMessage {}

extension ActorRef: SWIMAddressablePeer where Message: AnySWIMMessage {
    public var node: ClusterMembership.Node {
        .init(protocol: self.address.node.node.protocol, host: self.address.node.host, port: self.address.node.port, uid: self.address.node.nid.value)
    }
}

extension ActorRef: SWIMPeer where Message == SWIM.Message {
    public func ping(
        payload: SWIM.GossipPayload,
        from origin: SWIMAddressablePeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        pprint("ASK: ping >>> TO [\(self)]")
        self.ask(for: SWIM.PingResponse.self, timeout: .nanoseconds(timeout.nanoseconds)) { replyTo in
            SWIM.Message.remote(.ping(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber))
        }._onComplete(onComplete)
    }

    public func pingRequest(
        target: SWIMAddressablePeer, payload: SWIM.GossipPayload, from origin: SWIMAddressablePeer,
        timeout: DispatchTimeInterval, sequenceNumber: SWIM.SequenceNumber, onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        pprint("ASK: ping request >>> TO [\(self)]")
        self.ask(for: SWIM.PingResponse.self, timeout: .nanoseconds(timeout.nanoseconds)) { replyTo in
            SWIM.Message.remote(.pingRequest(target: target as! SWIM.Ref, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber))
        }._onComplete(onComplete)
    }
}

extension ActorRef: SWIMPingOriginPeer where Message == SWIM.PingResponse {
    public func ack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: SWIMAddressablePeer, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload) {
        self.tell(.ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
    }

    public func nack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: SWIMAddressablePeer) {
        self.tell(.nack(target: target, sequenceNumber: sequenceNumber))
    }
}
