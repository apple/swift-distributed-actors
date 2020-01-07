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

extension Membership: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterMembership

    func toProto(context: ActorSerializationContext) throws -> ProtoClusterMembership {
        var proto = InternalProtobufRepresentation()
        proto.members = try self._members.values.map {
            try $0.toProto(context: context)
        }
        if let leader = self.leader {
            proto.leaderNode = try leader.node.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoClusterMembership, context: ActorSerializationContext) throws {
        self._members = [:]
        self._members.reserveCapacity(proto.members.count)
        for protoMember in proto.members {
            let member = try Member(fromProto: protoMember, context: context)
            self._members[member.node] = member
        }
        if proto.hasLeaderNode {
            self._leaderNode = try UniqueNode(fromProto: proto.leaderNode, context: context)
        } else {
            self._leaderNode = nil
        }
    }
}

extension Member: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterMember

    func toProto(context: ActorSerializationContext) throws -> ProtoClusterMember {
        var proto = InternalProtobufRepresentation()
        proto.node = try self.node.toProto(context: context)
        proto.status = self.status.toProto(context: context)
        proto.reachability = try self.reachability.toProto(context: context)
        if let number = self.upNumber {
            proto.upNumber = UInt32(number)
        }
        return proto
    }

    init(fromProto proto: ProtoClusterMember, context: ActorSerializationContext) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("node", type: "\(InternalProtobufRepresentation.self)")
        }
        self.node = try .init(fromProto: proto.node, context: context)
        self.status = try .init(fromProto: proto.status, context: context)
        self.reachability = try .init(fromProto: proto.reachability, context: context)
        self.upNumber = proto.upNumber == 0 ? nil : Int(proto.upNumber)
    }
}

// not conforming to InternalProtobufRepresentable since it is a raw `enum` not a Message
extension MemberReachability {
    func toProto(context: ActorSerializationContext) throws -> ProtoClusterMemberReachability {
        switch self {
        case .reachable:
            return .reachable
        case .unreachable:
            return .unreachable
        }
    }

    init(fromProto proto: ProtoClusterMemberReachability, context: ActorSerializationContext) throws {
        switch proto {
        case .unspecified:
            throw SerializationError.missingField("reachability", type: "\(ProtoClusterMemberReachability.self)")
        case .UNRECOGNIZED(let n):
            throw SerializationError.missingField("reachability:\(n)", type: "\(ProtoClusterMemberReachability.self)")
        case .reachable:
            self = .reachable
        case .unreachable:
            self = .unreachable
        }
    }
}

// not conforming to InternalProtobufRepresentable since this is a raw `enum` not a Message
extension MemberStatus {
    func toProto(context: ActorSerializationContext) -> ProtoClusterMemberStatus {
        var proto = ProtoClusterMemberStatus()
        switch self {
        case .joining:
            proto = .joining
        case .up:
            proto = .up
        case .down:
            proto = .down
        case .leaving:
            proto = .leaving
        case .removed:
            proto = .removed
        }
        return proto
    }

    init(fromProto proto: ProtoClusterMemberStatus, context: ActorSerializationContext) throws {
        switch proto {
        case .unspecified:
            throw SerializationError.missingField("status", type: "\(ProtoClusterMemberStatus.self)")
        case .UNRECOGNIZED(let n):
            throw SerializationError.missingField("status:\(n)", type: "\(ProtoClusterMemberStatus.self)")
        case .joining:
            self = .joining
        case .up:
            self = .up
        case .down:
            self = .down
        case .leaving:
            self = .leaving
        case .removed:
            self = .removed
        }
    }
}

extension Membership.Gossip: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterMembershipGossip

    func toProto(context: ActorSerializationContext) throws -> InternalProtobufRepresentation {
        var proto = InternalProtobufRepresentation()
//        switch self {
//        case .update(let from, let members):
        fatalError("TODO: implement me") // FIXME:
//            proto.from = try from.toProto(context: context)
//            proto.members = try members.map { try $0.toProto(context: context) }
//        }
//        return proto
    }

    init(fromProto proto: InternalProtobufRepresentation, context: ActorSerializationContext) throws {
        fatalError("TODO: implement me") // FIXME:
//        guard proto.hasFrom else {
//            throw SerializationError.missingField("from", type: "\(InternalProtobufRepresentation.self)")
//        }
//        let from = try UniqueNode(fromProto: proto.from, context: context)
//        let members = try proto.members.map { try Member(fromProto: $0, context: context) }
//        self = .update(from: from, members)
    }
}
