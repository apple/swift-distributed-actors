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
        case .requestMembershipChange(let event):
            proto.clusterEvent = try event.toProto(context: context)
        case .gossip(let gossip):
            proto.gossip = try gossip.toProto(context: context)
        default:
            fatalError("Serializer not implemented for: \(String(reflecting: type(of: self)))")
        }
        return proto
    }

    init(fromProto proto: ProtoClusterShellMessage, context: ActorSerializationContext) throws {
        switch proto.message {
        case .some(.clusterEvent(let protoEvent)):
            self = try .requestMembershipChange(.init(fromProto: protoEvent, context: context))
        case .some(.gossip(let protoGossip)):
//            self = try .gossip(
//                .update(
//                    from: .init(fromProto: protoGossip.from, context: context),
            fatalError("TODO: implement serialization") // protoGossip.members.map { try Member(fromProto: $0, context: context) }
//                )
//            )
        case .none:
            throw SerializationError.missingField("message", type: "\(InternalProtobufRepresentation.self)")
        }
    }
}
