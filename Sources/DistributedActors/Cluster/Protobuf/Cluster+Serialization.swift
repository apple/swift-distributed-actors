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
        case .clusterEvent(let event):
            proto.clusterEvent = try event.toProto(context: context)
        default:
            fatalError("NOT IMPLEMENTED")
        }
        return proto
    }

    init(fromProto proto: ProtoClusterShellMessage, context: ActorSerializationContext) throws {
        switch proto.message {
        case .some(.clusterEvent(let protoEvent)):
            self = try .clusterEvent(.init(fromProto: protoEvent, context: context))
        case .none:
            throw SerializationError.missingField("message", type: "\(InternalProtobufRepresentation.self)")
        }
    }
}
