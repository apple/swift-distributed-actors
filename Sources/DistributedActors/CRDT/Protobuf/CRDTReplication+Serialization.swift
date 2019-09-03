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
            fatalError("Only CRDT.Replicator.Message.remoteCommand can be sent remotely! Was: \(self)")
        }

        switch message {
        case .write(let id, let crdtOrDelta, let replyTo):
            traceLog_Serialization("\(self)")
            var write = ProtoCRDTWrite()
            write.identity = id.toProto(context: context)
            write.replyTo = replyTo.toProto(context: context)

            guard let serializerId = context.system.serialization.serializerIdFor(metaType: crdtOrDelta.metaType) else {
                throw SerializationError.noSerializerRegisteredFor(hint: "\(crdtOrDelta.metaType)")
            }
            write.envelope = try CRDTEnvelope(serializerId: serializerId, crdtOrDelta).toProto(context: context)
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
            guard write.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: write.identity, context: context)

            guard write.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<CRDT.Replicator.RemoteCommand.WriteResult>(fromProto: write.replyTo, context: context)

            guard write.hasEnvelope else {
                throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
            }
            let envelope = try CRDTEnvelope(fromProto: write.envelope, context: context)

            self = .remoteCommand(.write(id, envelope.underlying, replyTo: replyTo))
        }
    }
}
