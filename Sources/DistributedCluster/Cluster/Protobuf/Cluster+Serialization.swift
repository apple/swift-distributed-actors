//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension ClusterShell.Message: _InternalProtobufRepresentable {
    typealias ProtobufRepresentation = _ProtoClusterShellMessage

    // FIXME: change this completely
    func toProto(context: Serialization.Context) throws -> _ProtoClusterShellMessage {
        var proto = _ProtoClusterShellMessage()

        switch self {
        case .requestMembershipChange(let event):
            proto.clusterEvent = try event.toProto(context: context)
        case .inbound(.restInPeace(let target, let from)):
            var protoRIP = _ProtoClusterRestInPeace()
            protoRIP.targetNode = try target.toProto(context: context)
            protoRIP.fromNode = try from.toProto(context: context)
            var protoInbound = _ProtoClusterInbound()
            protoInbound.restInPeace = protoRIP
            proto.inbound = protoInbound
        default:
            fatalError("Serializer not implemented for: [\(self)]:\(String(reflecting: type(of: self)))")
        }
        return proto
    }

    init(fromProto proto: _ProtoClusterShellMessage, context: Serialization.Context) throws {
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
                throw SerializationError(.missingField("inbound.message", type: "\(_ProtoClusterInbound.self)"))
            }
        case .none:
            throw SerializationError(.missingField("message", type: "\(ProtobufRepresentation.self)"))
        }
    }
}
