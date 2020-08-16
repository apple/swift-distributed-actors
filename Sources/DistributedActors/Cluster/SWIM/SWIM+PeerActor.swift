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
import SWIM
import enum Dispatch.DispatchTimeInterval

extension SWIM {
    typealias PeerRef = ActorRef<SWIM.Message>
    typealias Ref = ActorRef<SWIM.Message>

    typealias PingOriginRef = ActorRef<SWIM.PingResponse>
    typealias PingRequestOriginRef = ActorRef<SWIM.PingResponse>

    typealias Shell = SWIMActorShell
}

extension ActorRef: AddressableSWIMPeer {

    public var node: ClusterMembership.Node {
        get {
            guard let node = self.address.node else {
                fatalError("SWIM Peers always must have a node; in actor's case this should be the 'local' node if no node is set explicitly")
            }

            return .init(protocol: node.node.protocol, host: node.host, port: node.port, uid: UInt64(node.nid.value)) // TODO: those integer conversions
        }
        set {
            fatalError("EHHHH") // FIXME
        }
    }
}

extension ActorRef: SWIMPeer where Message == SWIM.Message {

    public func ping(
        payload: SWIM.GossipPayload,
        from origin: AddressableSWIMPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> ()
    ) {
        let response: AskResponse<SWIM.PingResponse> = self.ask(for: SWIM.PingResponse.self, timeout: .nanoseconds(timeout.nanoseconds)) { replyTo in
            SWIM.Message.remote(.ping(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber))
        }

        response._onComplete(onComplete)
    }

    public func pingRequest(
        target: AddressableSWIMPeer, payload: SWIM.GossipPayload, from origin: AddressableSWIMPeer,
        timeout: DispatchTimeInterval, sequenceNumber: SWIM.SequenceNumber, onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> ()) {
        let response: AskResponse<SWIM.PingResponse> = self.ask(for: SWIM.PingResponse.self, timeout: .nanoseconds(timeout.nanoseconds)) { replyTo in
            SWIM.Message.remote(.pingRequest(target: target as! SWIM.Ref, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber))
        }

        response._onComplete(onComplete)
    }
}

extension ActorRef: SWIMPingOriginPeer where Message == SWIM.PingResponse {

    public func ack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: AddressableSWIMPeer, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload) {
        self.tell(.ack(target: target.node, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
    }

    public func nack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: AddressableSWIMPeer) {
        self.tell(.nack(target: target.node, sequenceNumber: sequenceNumber))
    }
}
