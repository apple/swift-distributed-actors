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


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension SWIM.Message: ProtobufRepresentable {
    typealias ProtobufType = ProtoSWIMMessage

    func toProto(context: ActorSerializationContext) -> ProtoSWIMMessage {
        var proto = ProtoSWIMMessage()
        guard case SWIM.Message.remote(let message) = self else {
            fatalError("SWIM.Message.local should never be sent remotely.")
        }

        switch message {
        case .ping(let lastKnownStatus, let replyTo, let payload):
            var ping = ProtoSWIMPing()
            ping.lastKnownStatus = lastKnownStatus.toProto(context: context)
            ping.replyTo = replyTo.toProto(context: context)
            ping.payload = payload.toProto(context: context)
            proto.ping = ping
        case .pingReq(let target, let lastKnownStatus, let replyTo, let payload):
            var pingRequest = ProtoSWIMPingRequest()
            pingRequest.target = target.toProto(context: context)
            pingRequest.lastKnownStatus = lastKnownStatus.toProto(context: context)
            pingRequest.replyTo = replyTo.toProto(context: context)
            pingRequest.payload = payload.toProto(context: context)
            proto.pingRequest = pingRequest
        }

        return proto
    }

    init(fromProto proto: ProtoSWIMMessage, context: ActorSerializationContext) throws {
        guard let request = proto.request else {
            throw SerializationError.missingField("request", type: String(describing: SWIM.Message.self))
        }

        switch request {
        case .ping(let ping):
            let status = try SWIM.Status(fromProto: ping.lastKnownStatus, context: context)
            let replyTo = try ActorRef<SWIM.Ack>(fromProto: ping.replyTo, context: context)
            let payload = try SWIM.Payload(fromProto: ping.payload, context: context)
            self = .remote(.ping(lastKnownStatus: status, replyTo: replyTo, payload: payload))
        case .pingRequest(let pingRequest):
            let target = try ActorRef<SWIM.Message>(fromProto: pingRequest.target, context: context)
            let status = try SWIM.Status(fromProto: pingRequest.lastKnownStatus, context: context)
            let replyTo = try ActorRef<SWIM.Ack>(fromProto: pingRequest.replyTo, context: context)
            let payload = try SWIM.Payload(fromProto: pingRequest.payload, context: context)
            self = .remote(.pingReq(target: target, lastKnownStatus: status, replyTo: replyTo, payload: payload))
        }
    }
}

extension SWIM.Status: ProtobufRepresentable {
    typealias ProtobufType = ProtoSWIMStatus

    func toProto(context: ActorSerializationContext) -> ProtoSWIMStatus {
        var proto = ProtoSWIMStatus()
        switch self {
        case .alive(let incarnation):
            proto.type = .alive
            proto.incarnation = incarnation
        case .suspect(let incarnation):
            proto.type = .suspect
            proto.incarnation = incarnation
        case .unreachable(let incarnation):
            proto.type = .unreachable
            proto.incarnation = incarnation
        case .dead:
            proto.type = .dead
            proto.incarnation = 0
        }

        return proto
    }

    init(fromProto proto: ProtoSWIMStatus, context: ActorSerializationContext) throws {
        switch proto.type {
        case .alive:
            self = .alive(incarnation: proto.incarnation)
        case .suspect:
            self = .suspect(incarnation: proto.incarnation)
        case .unreachable:
            self = .unreachable(incarnation: proto.incarnation)
        case .dead:
            self = .dead
        case .UNRECOGNIZED(let num):
            throw SerializationError.unknownEnumValue(num)
        }
    }
}

extension SWIM.Payload: ProtobufRepresentable {
    typealias ProtobufType = ProtoSWIMPayload

    func toProto(context: ActorSerializationContext) -> ProtoSWIMPayload {
        var payload = ProtoSWIMPayload()
        if case .membership(let members) = self {
            payload.member = members.map { $0.toProto(context: context) }
        }

        return payload
    }

    init(fromProto proto: ProtoSWIMPayload, context: ActorSerializationContext) throws {
        if proto.member.isEmpty {
            self = .none
        } else {
            let members = try proto.member.map { proto in try SWIM.Member(fromProto: proto, context: context) }
            self = .membership(members)
        }
    }
}

extension SWIM.Member: ProtobufRepresentable {
    typealias ProtobufType = ProtoSWIMMember

    func toProto(context: ActorSerializationContext) -> ProtoSWIMMember {
        var proto = ProtoSWIMMember()
        proto.address = self.ref.toProto(context: context)
        proto.status = self.status.toProto(context: context)
        return proto
    }

    init(fromProto proto: ProtoSWIMMember, context: ActorSerializationContext) throws {
        let address = try ActorAddress(fromProto: proto.address, context: context)
        let ref = context.resolveActorRef(SWIM.Message.self, identifiedBy: address)
        let status = try SWIM.Status(fromProto: proto.status, context: context)
        self.init(ref: ref, status: status, protocolPeriod: 0)
    }
}

extension SWIM.Ack: ProtobufRepresentable {
    typealias ProtobufType = ProtoSWIMAck

    func toProto(context: ActorSerializationContext) -> ProtoSWIMAck {
        var proto = ProtoSWIMAck()
        proto.pinged = self.pinged.toProto(context: context)
        proto.incarnation = self.incarnation
        proto.payload = self.payload.toProto(context: context)
        return proto
    }

    init(fromProto proto: ProtoSWIMAck, context: ActorSerializationContext) throws {
        let pinged = context.resolveActorRef(SWIM.Message.self, identifiedBy: try ActorAddress(fromProto: proto.pinged, context: context))
        let payload = try SWIM.Payload(fromProto: proto.payload, context: context)
        self.init(pinged: pinged, incarnation: proto.incarnation, payload: payload)
    }
}
