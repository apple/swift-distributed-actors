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

import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension Cluster.Membership: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoClusterMembership

    public func toProto(context: Serialization.Context) throws -> _ProtoClusterMembership {
        var proto = ProtobufRepresentation()
        proto.members = try self._members.values.map {
            try $0.toProto(context: context)
        }
        if let leader = self.leader {
            proto.leaderNode = try leader.node.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: _ProtoClusterMembership, context: Serialization.Context) throws {
        self._members = [:]
        self._members.reserveCapacity(proto.members.count)
        for protoMember in proto.members {
            let member = try Cluster.Member(fromProto: protoMember, context: context)
            self._members[member.node] = member
        }
        if proto.hasLeaderNode {
            self._leaderNode = try Cluster.Node(fromProto: proto.leaderNode, context: context)
        } else {
            self._leaderNode = nil
        }
    }
}

extension Cluster.Member: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoClusterMember

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.node = try self.node.toProto(context: context)
        proto.status = try self.status.toProto(context: context)
        proto.reachability = try self.reachability.toProto(context: context)
        if let number = self._upNumber {
            proto.upNumber = UInt32(number)
        }
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasNode else {
            throw SerializationError(.missingField("node", type: "\(ProtobufRepresentation.self)"))
        }
        self.node = try .init(fromProto: proto.node, context: context)
        self.status = try .init(fromProto: proto.status, context: context)
        self.reachability = try .init(fromProto: proto.reachability, context: context)
        self._upNumber = proto.upNumber == 0 ? nil : Int(proto.upNumber)
    }
}

// not conforming to _InternalProtobufRepresentable since it is a raw `enum` not a Message
extension Cluster.MemberReachability {
    func toProto(context: Serialization.Context) throws -> _ProtoClusterMemberReachability {
        switch self {
        case .reachable:
            return .reachable
        case .unreachable:
            return .unreachable
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            throw SerializationError(
                .unableToSerialize(hint: "\(Self.self) is [\(self)]. This should not happen, please file an issue.")
            )
        }
    }

    init(fromProto proto: _ProtoClusterMemberReachability, context: Serialization.Context) throws {
        switch proto {
        case .unspecified:
            throw SerializationError(.missingField("reachability", type: "\(_ProtoClusterMemberReachability.self)"))
        case .UNRECOGNIZED(let n):
            throw SerializationError(
                .missingField("reachability:\(n)", type: "\(_ProtoClusterMemberReachability.self)")
            )
        case .reachable:
            self = .reachable
        case .unreachable:
            self = .unreachable
        }
    }
}

// not conforming to _InternalProtobufRepresentable since this is a raw `enum` not a Message
extension Cluster.MemberStatus {
    func toProto(context: Serialization.Context) throws -> _ProtoClusterMemberStatus {
        var proto = _ProtoClusterMemberStatus()
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
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            throw SerializationError(
                .unableToSerialize(hint: "\(Self.self) is [\(self)]. This should not happen, please file an issue.")
            )
        }
        return proto
    }

    init(fromProto proto: _ProtoClusterMemberStatus, context: Serialization.Context) throws {
        switch proto {
        case .unspecified:
            throw SerializationError(.missingField("status", type: "\(_ProtoClusterMemberStatus.self)"))
        case .UNRECOGNIZED(let n):
            throw SerializationError(.missingField("status:\(n)", type: "\(_ProtoClusterMemberStatus.self)"))
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
