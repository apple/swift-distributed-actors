//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.Message

extension CRDT.Replicator.Message: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTReplicatorMessage

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTReplicatorMessage {
        var proto = ProtoCRDTReplicatorMessage()
        guard case .remoteCommand(let message) = self else {
            fatalError("Only CRDT.Replicator.Message.remoteCommand can be sent remotely.")
        }

        switch message {
        case .write(let id, let data, let replyTo):
            var write = ProtoCRDTWrite()
            write.identity = id.toProto(context: context)
            write.replyTo = replyTo.toProto(context: context)

            var protoData = ProtoReplicatedData()
            switch data {
            case let data as AnyCvRDT:
                protoData.cvrdt = try data.toProto(context: context)
            case let data as AnyDeltaCRDT:
                protoData.deltaCrdt = try data.toProto(context: context)
            default:
                fatalError("Only AnyCvRDT and AnyDeltaCRDT are supported")
            }
            write.data = protoData
            proto.write = write
        case .writeDelta(let id, let delta, let replyTo):
            fatalError("to be implemented")
        case .read(let id, let replyTo):
            fatalError("to be implemented")
        case .delete(let id, let replyTo):
            fatalError("to be implemented")
        }

        return proto
    }

    init(fromProto proto: ProtoCRDTReplicatorMessage, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: CRDT.Replicator.Message.self))
        }

        switch value {
        case .write(let write):
            let id = CRDT.Identity(fromProto: write.identity, context: context)
            let replyTo = try ActorRef<CRDT.Replicator.RemoteCommand.WriteResult>(fromProto: write.replyTo, context: context)

            guard let payload = write.data.payload else {
                throw SerializationError.missingField("data", type: "CRDT.Replicator.RemoteCommand.write")
            }

            let data: CRDT.Replicator.ReplicatedData
            switch payload {
            case .cvrdt(let payload):
                data = try AnyCvRDT(fromProto: payload, context: context)
            case .deltaCrdt(let payload):
                data = try AnyDeltaCRDT(fromProto: payload, context: context)
            }

            self = .remoteCommand(.write(id, data, replyTo: replyTo))
        }
    }
}
