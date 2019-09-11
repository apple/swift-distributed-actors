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

    private typealias WriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    private typealias ReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    private typealias DeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTReplicatorMessage {
        guard case .remoteCommand(let message) = self else {
            fatalError("Only CRDT.Replicator.Message.remoteCommand can be sent remotely! Was: \(self)")
        }

        var proto = ProtoCRDTReplicatorMessage()
        switch message {
        case .write(let id, let data, let replyTo):
            traceLog_Serialization("\(self)")

            var protoWrite = ProtoCRDTWrite()
            protoWrite.identity = id.toProto(context: context)
            protoWrite.envelope = try data.asCRDTEnvelope(context).toProto(context: context)
            protoWrite.replyTo = replyTo.toProto(context: context)
            proto.write = protoWrite
        case .writeDelta(let id, let delta, let replyTo):
            traceLog_Serialization("\(self)")

            var protoWrite = ProtoCRDTWrite()
            protoWrite.identity = id.toProto(context: context)
            protoWrite.envelope = try delta.asCRDTEnvelope(context).toProto(context: context)
            protoWrite.replyTo = replyTo.toProto(context: context)
            proto.writeDelta = protoWrite
        case .read(let id, let replyTo):
            var protoRead = ProtoCRDTRead()
            protoRead.identity = id.toProto(context: context)
            protoRead.replyTo = replyTo.toProto(context: context)
            proto.read = protoRead
        case .delete(let id, let replyTo):
            var protoDelete = ProtoCRDTDelete()
            protoDelete.identity = id.toProto(context: context)
            protoDelete.replyTo = replyTo.toProto(context: context)
            proto.delete = protoDelete
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReplicatorMessage, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: CRDT.Replicator.Message.self))
        }

        switch value {
        case .write(let protoWrite):
            let id = try protoWrite.identity(context: context)
            let envelope = try protoWrite.envelope(context: context)
            let replyTo: ActorRef<WriteResult> = try protoWrite.replyTo(context: context)
            self = .remoteCommand(.write(id, envelope.underlying, replyTo: replyTo))
        case .writeDelta(let protoWrite):
            let id = try protoWrite.identity(context: context)
            let envelope = try protoWrite.envelope(context: context)
            let replyTo: ActorRef<WriteResult> = try protoWrite.replyTo(context: context)
            self = .remoteCommand(.writeDelta(id, delta: envelope.underlying, replyTo: replyTo))
        case .read(let protoRead):
            guard protoRead.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: protoRead.identity, context: context)

            guard protoRead.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<ReadResult>(fromProto: protoRead.replyTo, context: context)

            self = .remoteCommand(.read(id, replyTo: replyTo))
        case .delete(let protoDelete):
            guard protoDelete.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: protoDelete.identity, context: context)

            guard protoDelete.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<DeleteResult>(fromProto: protoDelete.replyTo, context: context)

            self = .remoteCommand(.delete(id, replyTo: replyTo))
        }
    }
}

extension ProtoCRDTWrite {
    internal func identity(context: ActorSerializationContext) throws -> CRDT.Identity {
        guard self.hasIdentity else {
            throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
        }
        return CRDT.Identity(fromProto: self.identity, context: context)
    }

    internal func replyTo<Message>(context: ActorSerializationContext) throws -> ActorRef<Message> {
        guard self.hasReplyTo else {
            throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
        }
        return try ActorRef<Message>(fromProto: self.replyTo, context: context)
    }

    internal func envelope(context: ActorSerializationContext) throws -> CRDTEnvelope {
        guard self.hasEnvelope else {
            throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
        }
        return try CRDTEnvelope(fromProto: self.envelope, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.RemoteCommand.WriteResult and WriteError

extension CRDT.Replicator.RemoteCommand.WriteResult: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTWriteResult

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTWriteResult {
        var proto = ProtoCRDTWriteResult()
        switch self {
        case .success:
            proto.type = .success
        case .failed(let error):
            proto.type = .failed
            proto.error = error.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTWriteResult, context: ActorSerializationContext) throws {
        switch proto.type {
        case .success:
            self = .success
        case .failed:
            guard proto.hasError else {
                throw SerializationError.missingField("error", type: String(describing: CRDT.Replicator.RemoteCommand.WriteResult.self))
            }
            let error = try CRDT.Replicator.RemoteCommand.WriteError(fromProto: proto.error, context: context)

            self = .failed(error)
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.WriteResult.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTWriteResult.type field.")
        }
    }
}

extension CRDT.Replicator.RemoteCommand.WriteError: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTWriteError

    func toProto(context: ActorSerializationContext) -> ProtoCRDTWriteError {
        var proto = ProtoCRDTWriteError()
        switch self {
        case .missingCRDTForDelta:
            proto.type = .missingCrdtForDelta
        case .incorrectDeltaType(let hint):
            proto.type = .incorrectDeltaType
            proto.hint = hint
        case .cannotWriteDeltaForNonDeltaCRDT:
            proto.type = .cannotWriteDeltaForNonDeltaCrdt
        case .inputAndStoredDataTypeMismatch(let hint):
            proto.type = .inputAndStoredDataTypeMismatch
            proto.hint = hint
        case .unsupportedCRDT:
            proto.type = .unsupportedCrdt
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTWriteError, context: ActorSerializationContext) throws {
        switch proto.type {
        case .missingCrdtForDelta:
            self = .missingCRDTForDelta
        case .incorrectDeltaType:
            self = .incorrectDeltaType(hint: proto.hint)
        case .cannotWriteDeltaForNonDeltaCrdt:
            self = .cannotWriteDeltaForNonDeltaCRDT
        case .inputAndStoredDataTypeMismatch:
            self = .inputAndStoredDataTypeMismatch(hint: proto.hint)
        case .unsupportedCrdt:
            self = .unsupportedCRDT
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.WriteError.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTWriteError.type field.")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.RemoteCommand.ReadResult and ReadError

extension CRDT.Replicator.RemoteCommand.ReadResult: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTReadResult

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTReadResult {
        var proto = ProtoCRDTReadResult()
        switch self {
        case .success(let data):
            proto.type = .success
            proto.envelope = try data.asCRDTEnvelope(context).toProto(context: context)
        case .failed(let error):
            proto.type = .failed
            proto.error = error.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReadResult, context: ActorSerializationContext) throws {
        switch proto.type {
        case .success:
            guard proto.hasEnvelope else {
                throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
            }
            let envelope = try CRDTEnvelope(fromProto: proto.envelope, context: context)

            self = .success(envelope.underlying)
        case .failed:
            guard proto.hasError else {
                throw SerializationError.missingField("error", type: String(describing: CRDT.Replicator.RemoteCommand.ReadResult.self))
            }
            let error = try CRDT.Replicator.RemoteCommand.ReadError(fromProto: proto.error, context: context)

            self = .failed(error)
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.ReadResult.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTReadResult.type field.")
        }
    }
}

extension CRDT.Replicator.RemoteCommand.ReadError: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTReadError

    func toProto(context: ActorSerializationContext) -> ProtoCRDTReadError {
        var proto = ProtoCRDTReadError()
        switch self {
        case .notFound:
            proto.type = .notFound
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReadError, context: ActorSerializationContext) throws {
        switch proto.type {
        case .notFound:
            self = .notFound
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.ReadError.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTReadError.type field.")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.RemoteCommand.DeleteResult

extension CRDT.Replicator.RemoteCommand.DeleteResult: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTDeleteResult

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTDeleteResult {
        var proto = ProtoCRDTDeleteResult()
        switch self {
        case .success:
            proto.type = .success
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTDeleteResult, context: ActorSerializationContext) throws {
        switch proto.type {
        case .success:
            self = .success
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.DeleteResult.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTDeleteResult.type field.")
        }
    }
}
