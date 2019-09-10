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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.Message

extension CRDT.Replicator.Message: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTReplicatorMessage

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTReplicatorMessage {
        var proto = ProtoCRDTReplicatorMessage()
        guard case .remoteCommand(let message) = self else {
            fatalError("Only CRDT.Replicator.Message.remoteCommand can be sent remotely! Was: \(self)")
        }

        switch message {
        case .write(let id, let data, let replyTo):
            traceLog_Serialization("\(self)")

            var write = ProtoCRDTWrite()
            write.identity = id.toProto(context: context)
            write.replyTo = replyTo.toProto(context: context)

            guard let serializerId = context.system.serialization.serializerIdFor(metaType: data.metaType) else {
                throw SerializationError.noSerializerRegisteredFor(hint: "\(data.metaType)")
            }
            write.envelope = try CRDTEnvelope(serializerId: serializerId, data).toProto(context: context)

            proto.write = write
        case .writeDelta:
            fatalError("to be implemented")

        case .read:
            fatalError("to be implemented")

        case .delete:
            fatalError("to be implemented")
        }

        return proto
    }

    init(fromProto proto: ProtoCRDTReplicatorMessage, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: CRDT.Replicator.Message.self))
        }

        switch value {
        case .write(let protoWrite):
            guard protoWrite.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: protoWrite.identity, context: context)

            guard protoWrite.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<CRDT.Replicator.RemoteCommand.WriteResult>(fromProto: protoWrite.replyTo, context: context)

            guard protoWrite.hasEnvelope else {
                throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
            }
            let envelope = try CRDTEnvelope(fromProto: protoWrite.envelope, context: context)

            self = .remoteCommand(.write(id, envelope.underlying, replyTo: replyTo))
        }
    }
}
