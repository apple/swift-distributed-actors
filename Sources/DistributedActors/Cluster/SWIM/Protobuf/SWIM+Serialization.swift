//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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

extension SWIM.Status: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoSWIMStatus

    public func toProto(context: Serialization.Context) throws -> _ProtoSWIMStatus {
        var proto = _ProtoSWIMStatus()
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

    public init(fromProto proto: _ProtoSWIMStatus, context: Serialization.Context) throws {
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
            throw SerializationError(.missingField("type", type: String(describing: SWIM.Status.self)))
        case .UNRECOGNIZED(let num):
            throw SerializationError(.unknownEnumValue(num))
        }
    }
}

extension SWIM.GossipPayload: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoSWIMGossipPayload

    public func toProto(context: Serialization.Context) throws -> _ProtoSWIMGossipPayload {
        var payload = _ProtoSWIMGossipPayload()
        if case .membership(let members) = self {
            payload.member = try members.map {
                try $0.toProto(context: context)
            }
        }

        return payload
    }

    public init(fromProto proto: _ProtoSWIMGossipPayload, context: Serialization.Context) throws {
        precondition(Peer.self == SWIMActor.self)
        if proto.member.isEmpty {
            self = .none
        } else {
            let members: [SWIM.Member<SWIMActor>] = try proto.member.map { proto in
                try .init(fromProto: proto, context: context)
            }
            self = .membership(members as! [SWIM.Member<Peer>]) // as!-safe, since Peer always is SWIMActor in this implementation
        }
    }
}

extension SWIM.Member: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoSWIMMember

    public func toProto(context: Serialization.Context) throws -> _ProtoSWIMMember {
        var proto = _ProtoSWIMMember()
        guard let peer = self.peer as? SWIMActor else {
            throw SerializationError(.unableToSerialize(hint: "Expected peer to be \(SWIMActor.self) but was \(self.peer)!"))
        }
        proto.id = try peer.id.toProto(context: context)
        proto.status = try self.status.toProto(context: context)
        proto.protocolPeriod = self.protocolPeriod
        return proto
    }

    public init(fromProto proto: _ProtoSWIMMember, context: Serialization.Context) throws {
        precondition(Peer.self == SWIMActor.self)
        let id = try ActorID(fromProto: proto.id, context: context)
        let peer = try SWIMActor.resolve(id: id, using: context.system)
        let status = try SWIM.Status(fromProto: proto.status, context: context)
        let protocolPeriod = proto.protocolPeriod
        self.init(peer: peer as! Peer, status: status, protocolPeriod: protocolPeriod) // as!-safe since we only deal with Actor impls
    }
}

extension SWIM.PingResponse: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoSWIMPingResponse

    public func toProto(context: Serialization.Context) throws -> _ProtoSWIMPingResponse {
        var proto = _ProtoSWIMPingResponse()
        switch self {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            var ack = _ProtoSWIMPingResponse.Ack()
            guard let target = target as? SWIMActor else {
                throw SerializationError(.unableToSerialize(hint: "Can't serialize SWIM target as \(SWIMActor.self), was: \(target)"))
            }
            ack.target = try target.id.toProto(context: context)
            ack.incarnation = incarnation
            ack.payload = try payload.toProto(context: context)
            ack.sequenceNumber = sequenceNumber
            proto.ack = ack
        case .nack(let target, let sequenceNumber):
            var nack = _ProtoSWIMPingResponse.Nack()
            guard let target = target as? SWIMActor else {
                throw SerializationError(.unableToSerialize(hint: "Can't serialize SWIM target as \(SWIMActor.self), was: \(target)"))
            }
            nack.target = try target.id.toProto(context: context)
            nack.sequenceNumber = sequenceNumber
            proto.nack = nack
        case .timeout:
            throw SerializationError(.nonTransportableMessage(type: "\(self)"))
        }
        return proto
    }

    public init(fromProto proto: _ProtoSWIMPingResponse, context: Serialization.Context) throws {
        precondition(Peer.self == SWIMActor.self)
        guard let pingResponse = proto.pingResponse else {
            throw SerializationError(.missingField("pingResponse", type: String(describing: SWIM.PingResponse<SWIMActor, SWIMActor>.self)))
        }
        switch pingResponse {
        case .ack(let ack):
            let targetID = try ActorID(fromProto: ack.target, context: context)
            let target = try SWIMActor.resolve(id: targetID, using: context.system)
            let targetPeer = target as! Peer // as!-safe, since we only ever deal with Actor
            let payload = try SWIM.GossipPayload<Peer>(fromProto: ack.payload, context: context)
            let sequenceNumber = ack.sequenceNumber
            self = .ack(target: targetPeer, incarnation: ack.incarnation, payload: payload, sequenceNumber: sequenceNumber)

        case .nack(let nack):
            let targetID = try ActorID(fromProto: nack.target, context: context)
            let target = try SWIMActor.resolve(id: targetID, using: context.system)
            let targetPeer = target as! Peer // as!-safe, since we only ever deal with Actor impls
            let sequenceNumber = nack.sequenceNumber
            self = .nack(target: targetPeer, sequenceNumber: sequenceNumber)
        }
    }
}

extension ClusterMembership.Node: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoUniqueNode

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        var protoNode = _ProtoNode()
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
            throw SerializationError(.missingField("node", type: String(describing: Node.self)))
        }
        let protoNode: _ProtoNode = proto.node
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
