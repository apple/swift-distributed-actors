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
import Foundation
import SWIM

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension SWIM.Message: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        guard case SWIM.Message.remote(let message) = self else {
            fatalError("Only local SWIM.Message may be sent sent remotely, was: \(self)")
        }

        return try message.toProto(context: context)
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        self = try .remote(SWIM.RemoteMessage(fromProto: proto, context: context))
    }
}

extension SWIM.RemoteMessage: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMRemoteMessage

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        switch self {
        case .ping(let origin, let payload, let sequenceNumber):
            var ping = ProtoSWIMPing()
            ping.origin = try origin.toProto(context: context)
            ping.payload = try payload.toProto(context: context)
            ping.sequenceNumber = sequenceNumber
            proto.ping = ping
        case .pingRequest(let target, let origin, let payload, let sequenceNumber):
            var pingRequest = ProtoSWIMPingRequest()
            pingRequest.target = try target.toProto(context: context)
            pingRequest.origin = try origin.toProto(context: context)
            pingRequest.payload = try payload.toProto(context: context)
            pingRequest.sequenceNumber = sequenceNumber
            proto.pingRequest = pingRequest
        case .pingResponse(let response):
            proto.pingResponse = try response.toProto(context: context)
        }

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        switch proto.message {
        case .ping(let ping):
            let pingOriginAddress = try ActorAddress(fromProto: ping.origin, context: context)
            let pingOrigin: SWIM.PingOriginRef = context.resolveActorRef(identifiedBy: pingOriginAddress)

            let payload = try SWIM.GossipPayload(fromProto: ping.payload, context: context)
            let sequenceNumber = ping.sequenceNumber
            self = .ping(pingOrigin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let pingRequest):
            let targetAddress = try ActorAddress(fromProto: pingRequest.target, context: context)
            let target: ActorRef<SWIM.Message> = context.resolveActorRef(SWIM.Message.self, identifiedBy: targetAddress)

            let pingRequestOriginAddress = try ActorAddress(fromProto: pingRequest.origin, context: context)
            let pingRequestOrigin: SWIM.PingRequestOriginRef = context.resolveActorRef(identifiedBy: pingRequestOriginAddress)

            let payload = try SWIM.GossipPayload(fromProto: pingRequest.payload, context: context)
            let sequenceNumber = pingRequest.sequenceNumber
            self = .pingRequest(target: target, pingRequestOrigin: pingRequestOrigin, payload: payload, sequenceNumber: sequenceNumber)

        case .pingResponse(let pingResponse):
            self = .pingResponse(try SWIM.PingResponse(fromProto: pingResponse, context: context))

        case .none:
            throw SerializationError.missingField("request", type: String(describing: SWIM.Message.self))
        }
    }
}

extension SWIM.Status: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMStatus

    public func toProto(context: Serialization.Context) throws -> ProtoSWIMStatus {
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

    public init(fromProto proto: ProtoSWIMStatus, context: Serialization.Context) throws {
        switch proto.type {
        case .alive:
            self = .alive(incarnation: proto.incarnation)
        case .suspect:
            let suspectedBy = try Set(proto.suspectedBy.map { try ClusterMembership.Node(fromProto: $0, context: context) })
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

extension SWIM.GossipPayload: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMGossipPayload

    public func toProto(context: Serialization.Context) throws -> ProtoSWIMGossipPayload {
        var payload = ProtoSWIMGossipPayload()
        if case .membership(let members) = self {
            payload.member = try members.map {
                try $0.toProto(context: context)
            }
        }

        return payload
    }

    public init(fromProto proto: ProtoSWIMGossipPayload, context: Serialization.Context) throws {
        if proto.member.isEmpty {
            self = .none
        } else {
            let members = try proto.member.map { proto in
                try SWIM.Member(fromProto: proto, context: context)
            }
            self = .membership(members)
        }
    }
}

extension SWIM.Member: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMMember

    public func toProto(context: Serialization.Context) throws -> ProtoSWIMMember {
        var proto = ProtoSWIMMember()
        guard let actorPeer = self.peer as? SWIM.Ref else {
            throw SerializationError.unableToSerialize(hint: "Expected peer to be \(SWIM.Ref.self) but was \(self.peer)!")
        }
        proto.address = try actorPeer.toProto(context: context)
        proto.status = try self.status.toProto(context: context)
        proto.protocolPeriod = self.protocolPeriod
        return proto
    }

    public init(fromProto proto: ProtoSWIMMember, context: Serialization.Context) throws {
        let address = try ActorAddress(fromProto: proto.address, context: context)
        let peer = context.resolveActorRef(SWIM.Message.self, identifiedBy: address)
        let status = try SWIM.Status(fromProto: proto.status, context: context)
        let protocolPeriod = proto.protocolPeriod
        self.init(peer: peer, status: status, protocolPeriod: protocolPeriod)
    }
}

extension SWIM.PingResponse: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoSWIMPingResponse

    public func toProto(context: Serialization.Context) throws -> ProtoSWIMPingResponse {
        var proto = ProtoSWIMPingResponse()
        switch self {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            var ack = ProtoSWIMPingResponse.Ack()
            guard let targetRef = target as? SWIM.Ref else {
                throw SerializationError.unableToSerialize(hint: "Can't serialize SWIM target as \(SWIM.Ref.self), was: \(target)")
            }
            ack.target = try targetRef.toProto(context: context)
            ack.incarnation = incarnation
            ack.payload = try payload.toProto(context: context)
            ack.sequenceNumber = sequenceNumber
            proto.ack = ack
        case .nack(let target, let sequenceNumber):
            var nack = ProtoSWIMPingResponse.Nack()
            guard let targetRef = target as? SWIM.Ref else {
                throw SerializationError.unableToSerialize(hint: "Can't serialize SWIM target as \(SWIM.Ref.self), was: \(target)")
            }
            nack.target = try targetRef.toProto(context: context)
            nack.sequenceNumber = sequenceNumber
            proto.nack = nack
        case .timeout:
            throw SerializationError.nonTransportableMessage(type: "\(self)")
        }
        return proto
    }

    public init(fromProto proto: ProtoSWIMPingResponse, context: Serialization.Context) throws {
        guard let pingResponse = proto.pingResponse else {
            throw SerializationError.missingField("pingResponse", type: String(describing: SWIM.PingResponse.self))
        }
        switch pingResponse {
        case .ack(let ack):
            let targetAddress = try ActorAddress(fromProto: ack.target, context: context)
            let target: SWIM.Ref = context.resolveActorRef(identifiedBy: targetAddress)
            let payload = try SWIM.GossipPayload(fromProto: ack.payload, context: context)
            let sequenceNumber = ack.sequenceNumber
            self = .ack(target: target, incarnation: ack.incarnation, payload: payload, sequenceNumber: sequenceNumber)

        case .nack(let nack):
            let targetAddress = try ActorAddress(fromProto: nack.target, context: context)
            let target: SWIM.Ref = context.resolveActorRef(identifiedBy: targetAddress)
            let sequenceNumber = nack.sequenceNumber
            self = .nack(target: target, sequenceNumber: sequenceNumber)
        }
    }
}

extension ClusterMembership.Node: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoUniqueNode

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        var protoNode = ProtoNode()
        protoNode.protocol = self.protocol
        if let name = self.name {
            protoNode.system = name
        }
        protoNode.hostname = self.host
        protoNode.port = UInt32(self.port)
        proto.node = protoNode
        if let uid = self.uid {
            proto.nid = uid
        }
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("node", type: String(describing: Node.self))
        }
        let protoNode: ProtoNode = proto.node
        let `protocol` = protoNode.protocol
        let name: String?
        if protoNode.protocol != "" {
            name = protoNode.protocol
        } else {
            name = nil
        }
        let host = protoNode.hostname
        let port = Int(protoNode.port)

        let uid = proto.nid
        self.init(protocol: `protocol`, name: name, host: host, port: port, uid: uid)
    }
}
