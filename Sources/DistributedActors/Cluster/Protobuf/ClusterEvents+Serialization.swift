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

extension Cluster.Event: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterEvent

    func toProto(context: ActorSerializationContext) throws -> ProtoClusterEvent {
        var proto = ProtoClusterEvent()

        switch self {
        case .snapshot(let membership):
            proto.event = .snapshot(try membership.toProto(context: context))
        case .membershipChange(let change):
            proto.event = .membershipChange(try change.toProto(context: context))
        case .leadershipChange(let change):
            // technically should not be gossiped around, but let us cover all the messages of Cluster.Event
            proto.event = .leadershipChange(try change.toProto(context: context))
        default:
            fatalError("Serialization not implemented for: \(self)")
        }

        return proto
    }

    init(fromProto proto: ProtoClusterEvent, context: ActorSerializationContext) throws {
        switch proto.event {
        case .some(.membershipChange(let protoChange)):
            self = try .membershipChange(.init(fromProto: protoChange, context: context))
        case .some(.leadershipChange(let protoChange)):
            self = try .leadershipChange(.init(fromProto: protoChange, context: context))
        case .some(.snapshot(let protoMembership)):
            self = try .snapshot(.init(fromProto: protoMembership, context: context))
        case .none:
            fatalError("Unexpected attempt to serialize .none event in \(InternalProtobufRepresentation.self)")
        }
    }
}

extension Cluster.MembershipChange: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterMembershipChange

    func toProto(context: ActorSerializationContext) throws -> ProtoClusterMembershipChange {
        var proto = ProtoClusterMembershipChange()

        proto.node = try self.node.toProto(context: context)
        if let fromStatus = self.fromStatus {
            proto.fromStatus = fromStatus.toProto(context: context)
        }
        proto.toStatus = self.toStatus.toProto(context: context)

        return proto
    }

    init(fromProto proto: ProtoClusterMembershipChange, context: ActorSerializationContext) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("node", type: "\(Cluster.MembershipChange.self)")
        }

        self = try .init(
            node: .init(fromProto: proto.node, context: context),
            fromStatus: .init(fromProto: proto.fromStatus, context: context),
            toStatus: .init(fromProto: proto.toStatus, context: context)
        )
    }
}

extension Cluster.LeadershipChange: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterLeadershipChange

    func toProto(context: ActorSerializationContext) throws -> InternalProtobufRepresentation {
        var proto = InternalProtobufRepresentation()

        if let old = self.oldLeader {
            proto.oldLeader = try old.toProto(context: context)
        }
        if let new = self.newLeader {
            proto.newLeader = try new.toProto(context: context)
        }

        return proto
    }

    init(fromProto proto: InternalProtobufRepresentation, context: ActorSerializationContext) throws {
        if proto.hasOldLeader {
            self.oldLeader = try Cluster.Member(fromProto: proto.oldLeader, context: context)
        } else {
            self.oldLeader = nil
        }

        if proto.hasNewLeader {
            self.newLeader = try Cluster.Member(fromProto: proto.newLeader, context: context)
        } else {
            self.newLeader = nil
        }
    }
}
