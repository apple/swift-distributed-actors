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
    typealias ProtobufRepresentation = ProtoClusterShellMessage

    // FIXME: change this completely
    func toProto(context: Serialization.Context) throws -> ProtoClusterShellMessage {
        var proto = ProtoClusterShellMessage()

        switch self {
        case .requestMembershipChange(let event):
            proto.clusterEvent = try event.toProto(context: context)
        case .inbound(.restInPeace(let target, let from)):
            var protoRIP = ProtoClusterRestInPeace()
            protoRIP.targetNode = try target.toProto(context: context)
            protoRIP.fromNode = try from.toProto(context: context)
            var protoInbound = ProtoClusterInbound()
            protoInbound.restInPeace = protoRIP
            proto.inbound = protoInbound
        default:
            fatalError("Serializer not implemented for: [\(self)]:\(String(reflecting: type(of: self)))")
        }
        return proto
    }

    init(fromProto proto: ProtoClusterShellMessage, context: Serialization.Context) throws {
        switch proto.message {
        case .some(.clusterEvent(let protoEvent)):
            self = try .requestMembershipChange(.init(fromProto: protoEvent, context: context))
        case .some(.inbound(let inbound)):
            switch inbound.message {
            case .some(.restInPeace(let protoRIP)):
                self = try .inbound(
                    .restInPeace(
                        .init(fromProto: protoRIP.targetNode, context: context),
                        from: .init(fromProto: protoRIP.fromNode, context: context)
                    )
                )
            case .none:
                throw SerializationError.missingField("inbound.message", type: "\(ProtoClusterInbound.self)")
            }
        case .none:
            throw SerializationError.missingField("message", type: "\(ProtobufRepresentation.self)")
        }
    }
}
