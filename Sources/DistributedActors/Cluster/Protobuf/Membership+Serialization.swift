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

extension Cluster.Membership: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoClusterMembership

    public func toProto(context: Serialization.Context) throws -> ProtoClusterMembership {
        var proto = ProtobufRepresentation()
        proto.members = try self._members.values.map {
            try $0.toProto(context: context)
        }
        if let leader = self.leader {
            proto.leaderNode = try leader.uniqueNode.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoClusterMembership, context: Serialization.Context) throws {
        self._members = [:]
        self._members.reserveCapacity(proto.members.count)
        for protoMember in proto.members {
            let member = try Cluster.Member(fromProto: protoMember, context: context)
            self._members[member.uniqueNode] = member
        }
        if proto.hasLeaderNode {
            self._leaderNode = try UniqueNode(fromProto: proto.leaderNode, context: context)
        } else {
            self._leaderNode = nil
        }
    }
}

extension Cluster.Member: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoClusterMember

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.node = try self.uniqueNode.toProto(context: context)
        proto.status = self.status.toProto(context: context)
        proto.reachability = try self.reachability.toProto(context: context)
        if let number = self._upNumber {
            proto.upNumber = UInt32(number)
        }
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("node", type: "\(ProtobufRepresentation.self)")
        }
        self.uniqueNode = try .init(fromProto: proto.node, context: context)
        self.status = try .init(fromProto: proto.status, context: context)
        self.reachability = try .init(fromProto: proto.reachability, context: context)
        self._upNumber = proto.upNumber == 0 ? nil : Int(proto.upNumber)
    }
}

// not conforming to InternalProtobufRepresentable since it is a raw `enum` not a Message
extension Cluster.MemberReachability {
    func toProto(context: Serialization.Context) throws -> ProtoClusterMemberReachability {
        switch self {
        case .reachable:
            return .reachable
        case .unreachable:
            return .unreachable
        }
    }

    init(fromProto proto: ProtoClusterMemberReachability, context: Serialization.Context) throws {
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
extension Cluster.MemberStatus {
    func toProto(context: Serialization.Context) -> ProtoClusterMemberStatus {
        var proto = ProtoClusterMemberStatus()
        switch self {
        case .joining:
            proto = .joining
        case .up:
            proto = .up
        case .leaving:
            proto = .leaving
        case .down:
            proto = .down
        case .removed:
            proto = .removed
        }
        return proto
    }

    init(fromProto proto: ProtoClusterMemberStatus, context: Serialization.Context) throws {
        switch proto {
        case .unspecified:
            throw SerializationError.missingField("status", type: "\(ProtoClusterMemberStatus.self)")
        case .UNRECOGNIZED(let n):
            throw SerializationError.missingField("status:\(n)", type: "\(ProtoClusterMemberStatus.self)")
        case .joining:
            self = .joining
        case .up:
            self = .up
        case .leaving:
            self = .leaving
        case .down:
            self = .down
        case .removed:
            self = .removed
        }
    }
}
