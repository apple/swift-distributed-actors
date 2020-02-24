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

extension SWIM.Message: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        guard case SWIM.Message.remote(let message) = self else {
            fatalError("SWIM.Message.local should never be sent remotely.")
        }

        return try message.toProto(context: context)
    }

    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        self = try .remote(SWIM.RemoteMessage(fromProto: proto, context: context))
    }
}

extension SWIM.RemoteMessage: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        switch self {
        case .ping(let replyTo, let payload):
            var ping = ProtoSWIMPing()
            ping.replyTo = try replyTo.toProto(context: context)
            ping.payload = try payload.toProto(context: context)
            proto.ping = ping
        case .pingReq(let target, let replyTo, let payload):
            var pingRequest = ProtoSWIMPingRequest()
            pingRequest.target = try target.toProto(context: context)
            pingRequest.replyTo = try replyTo.toProto(context: context)
            pingRequest.payload = try payload.toProto(context: context)
            proto.pingRequest = pingRequest
        }

        return proto
    }

    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        switch proto.request {
        case .ping(let ping):
            let replyTo = try ActorRef<SWIM.PingResponse>(fromProto: ping.replyTo, context: context)
            let payload = try SWIM.Payload(fromProto: ping.payload, context: context)
            self = .ping(replyTo: replyTo, payload: payload)
        case .pingRequest(let pingRequest):
            let target = try ActorRef<SWIM.Message>(fromProto: pingRequest.target, context: context)
            let replyTo = try ActorRef<SWIM.PingResponse>(fromProto: pingRequest.replyTo, context: context)
            let payload = try SWIM.Payload(fromProto: pingRequest.payload, context: context)
            self = .pingReq(target: target, replyTo: replyTo, payload: payload)
        case .none:
            throw SerializationError.missingField("request", type: String(describing: SWIM.Message.self))
        }
    }
}

extension SWIM.Status: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMStatus

    func toProto(context: Serialization.Context) throws -> ProtoSWIMStatus {
        var proto = ProtoSWIMStatus()
        switch self {
        case .alive(let incarnation):
            proto.type = .alive
            proto.incarnation = incarnation
        case .suspect(let incarnation, let suspectedBy):
            proto.type = .suspect
            proto.incarnation = incarnation
            proto.suspectedBy = try suspectedBy.map { try $0.toProto(context: context) }
        case .unreachable(let incarnation):
            proto.type = .unreachable
            proto.incarnation = incarnation
        case .dead:
            proto.type = .dead
            proto.incarnation = 0
        }

        return proto
    }

    init(fromProto proto: ProtoSWIMStatus, context: Serialization.Context) throws {
        switch proto.type {
        case .alive:
            self = .alive(incarnation: proto.incarnation)
        case .suspect:
            let suspectedBy = try Set(proto.suspectedBy.map { try UniqueNode(fromProto: $0, context: context) })
            self = .suspect(incarnation: proto.incarnation, suspectedBy: suspectedBy)
        case .unreachable:
            self = .unreachable(incarnation: proto.incarnation)
        case .dead:
            self = .dead
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: SWIM.Status.self))
        case .UNRECOGNIZED(let num):
            throw SerializationError.unknownEnumValue(num)
        }
    }
}

extension SWIM.Payload: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMPayload

    func toProto(context: Serialization.Context) throws -> ProtoSWIMPayload {
        var payload = ProtoSWIMPayload()
        if case .membership(let members) = self {
            payload.member = try members.map { try $0.toProto(context: context) }
        }

        return payload
    }

    init(fromProto proto: ProtoSWIMPayload, context: Serialization.Context) throws {
        let members = try proto.member.map { proto in try SWIM.Member(fromProto: proto, context: context) }
        self = .membership(members)
    }
}

extension SWIM.Member: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMMember

    func toProto(context: Serialization.Context) throws -> ProtoSWIMMember {
        var proto = ProtoSWIMMember()
        proto.address = try self.ref.toProto(context: context)
        proto.status = try self.status.toProto(context: context)
        return proto
    }

    init(fromProto proto: ProtoSWIMMember, context: Serialization.Context) throws {
        let address = try ActorAddress(fromProto: proto.address, context: context)
        let ref = context.resolveActorRef(SWIM.Message.self, identifiedBy: address)
        let status = try SWIM.Status(fromProto: proto.status, context: context)
        self.init(ref: ref, status: status, protocolPeriod: 0)
    }
}

extension SWIM.PingResponse: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSWIMPingResponse

    func toProto(context: Serialization.Context) throws -> ProtoSWIMPingResponse {
        var proto = ProtoSWIMPingResponse()
        switch self {
        case .ack(let target, let payload):
            var ack = ProtoSWIMPingResponse.Ack()
            ack.target = try target.toProto(context: context)
            ack.payload = try payload.toProto(context: context)
            proto.ack = ack
        case .nack(let target):
            var nack = ProtoSWIMPingResponse.Nack()
            nack.target = try target.toProto(context: context)
            proto.nack = nack
        }
        return proto
    }

    init(fromProto proto: ProtoSWIMPingResponse, context: Serialization.Context) throws {
        guard let pingResponse = proto.pingResponse else {
            throw SerializationError.missingField("pingResponse", type: String(describing: SWIM.PingResponse.self))
        }
        switch pingResponse {
        case .ack(let ack):
            let target = context.resolveActorRef(SWIM.Message.self, identifiedBy: try ActorAddress(fromProto: ack.target, context: context))
            let payload = try SWIM.Payload(fromProto: ack.payload, context: context)
            self = .ack(target: target, payload: payload)
        case .nack(let nack):
            let target = context.resolveActorRef(SWIM.Message.self, identifiedBy: try ActorAddress(fromProto: nack.target, context: context))
            self = .nack(target: target)
        }
    }
}
