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

extension ClusterShell.Message: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterShellMessage

    // FIXME: change this completely
    func toProto(context: ActorSerializationContext) throws -> ProtoClusterShellMessage {
        var proto = ProtoClusterShellMessage()

        switch self {
        case .clusterEvent(.membershipChange(let change)):
            proto.membershipChange = try change.toProto(context: context)
        default:
            fatalError("NOT IMPLEMENTED")
        }
        return proto
    }

    init(fromProto proto: ProtoClusterShellMessage, context: ActorSerializationContext) throws {
        // FIXME: actual impl

        self = try .clusterEvent(.membershipChange(.init(fromProto: proto.membershipChange, context: context)))
    }
}

extension ClusterEvent: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoClusterEvent

    func toProto(context: ActorSerializationContext) throws -> ProtoClusterEvent {
        var proto = ProtoClusterEvent()

        switch self {
        case .membershipChange(let change):
            proto.membershipChange = try change.toProto(context: context)
        default:
            fatalError("TODO; implement me") // FIXME: implement
        }

        return proto
    }

    init(fromProto proto: ProtoClusterEvent, context: ActorSerializationContext) throws {
        switch proto.event {
        case .some(.membershipChange(let protoChange)):
            self = try .membershipChange(.init(fromProto: protoChange, context: context))
        default:
            fatalError("TODO")
        }
    }
}

extension MembershipChange: InternalProtobufRepresentable {
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
            throw SerializationError.missingField("node", type: "\(MembershipChange.self)")
        }

        self = try .init(
            node: .init(fromProto: proto.node, context: context),
            fromStatus: .init(fromProto: proto.fromStatus, context: context),
            toStatus: .init(fromProto: proto.toStatus, context: context)
        )
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
        case .UNRECOGNIZED:
            throw SerializationError.missingField("value", type: "\(ProtoClusterMemberStatus.self)")
        case .unspecified:
            throw SerializationError.missingField("value", type: "\(ProtoClusterMemberStatus.self)")
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
