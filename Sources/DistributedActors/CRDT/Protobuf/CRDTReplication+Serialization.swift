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
    typealias ProtobufRepresentation = ProtoCRDTReplicatorMessage

    private typealias WriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    private typealias ReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    private typealias DeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        guard case .remoteCommand(let remoteCommand) = self else {
            fatalError("Only CRDT.Replicator.Message.remoteCommand can be sent remotely! Was: \(self)")
        }

        var proto = ProtobufRepresentation()
        proto.remoteCommand = try remoteCommand.toProto(context: context)

        return proto
    }

    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasRemoteCommand else {
            throw SerializationError.missingField("remoteCommand", type: "\(CRDT.Replicator.Message.self)")
        }

        let remoteCommandProto = proto.remoteCommand
        self = try .remoteCommand(CRDT.Replicator.RemoteCommand(fromProto: remoteCommandProto, context: context))
    }
}

extension CRDT.Replicator.RemoteCommand: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTReplicatorRemoteCommand

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()

        switch self {
        case .write(let id, let crdt, let replyTo):
            traceLog_Serialization("\(self)")

            var protoWrite = ProtoCRDTWrite()
            protoWrite.identity = id.toProto(context: context)
            protoWrite.envelope = try ProtoCRDTEnvelope.serialize(context, crdt: crdt)
            protoWrite.replyTo = try replyTo.toProto(context: context)
            proto.write = protoWrite

        case .writeDelta(let id, let delta, let replyTo):
            traceLog_Serialization("\(self)")

            var protoWrite = ProtoCRDTWrite()
            protoWrite.identity = id.toProto(context: context)
            protoWrite.envelope = try ProtoCRDTEnvelope.serialize(context, crdt: delta)
            protoWrite.replyTo = try replyTo.toProto(context: context)
            proto.writeDelta = protoWrite

        case .read(let id, let replyTo):
            traceLog_Serialization("\(self)")

            var protoRead = ProtoCRDTRead()
            protoRead.identity = id.toProto(context: context)
            protoRead.replyTo = try replyTo.toProto(context: context)
            proto.read = protoRead

        case .delete(let id, let replyTo):
            traceLog_Serialization("\(self)")

            var protoDelete = ProtoCRDTDelete()
            protoDelete.identity = id.toProto(context: context)
            protoDelete.replyTo = try replyTo.toProto(context: context)
            proto.delete = protoDelete
        }
        return proto
    }

    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: CRDT.Replicator.Message.self))
        }

        switch value {
        case .write(let protoWrite):
            let id = try protoWrite.identity(context: context)
            let envelope = try protoWrite.envelope(context: context)
            let replyTo: ActorRef<WriteResult> = try protoWrite.replyTo(context: context)
            self = .write(id, envelope.underlying, replyTo: replyTo)

        case .writeDelta(let protoWrite):
            let id = try protoWrite.identity(context: context)
            let envelope = try protoWrite.envelope(context: context)
            let replyTo: ActorRef<WriteResult> = try protoWrite.replyTo(context: context)
            self = .writeDelta(id, delta: envelope.underlying, replyTo: replyTo)

        case .read(let protoRead):
            guard protoRead.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: protoRead.identity, context: context)

            guard protoRead.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<ReadResult>(fromProto: protoRead.replyTo, context: context)
            self = .read(id, replyTo: replyTo)

        case .delete(let protoDelete):
            guard protoDelete.hasIdentity else {
                throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
            }
            let id = CRDT.Identity(fromProto: protoDelete.identity, context: context)

            guard protoDelete.hasReplyTo else {
                throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
            }
            let replyTo = try ActorRef<DeleteResult>(fromProto: protoDelete.replyTo, context: context)
            self = .delete(id, replyTo: replyTo)
        }
    }
}

extension ProtoCRDTWrite {
    internal func identity(context: Serialization.Context) throws -> CRDT.Identity {
        guard self.hasIdentity else {
            throw SerializationError.missingField("identity", type: String(describing: CRDT.Replicator.Message.self))
        }
        return CRDT.Identity(fromProto: self.identity, context: context)
    }

    internal func replyTo<Message>(context: Serialization.Context) throws -> ActorRef<Message> {
        guard self.hasReplyTo else {
            throw SerializationError.missingField("replyTo", type: String(describing: CRDT.Replicator.Message.self))
        }
        return try ActorRef<Message>(fromProto: self.replyTo, context: context)
    }

    internal func envelope(context: Serialization.Context) throws -> CRDTEnvelope {
        guard self.hasEnvelope else {
            throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
        }
        return try CRDTEnvelope(fromProto: self.envelope, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator.RemoteCommand.WriteResult and WriteError

extension CRDT.Replicator.RemoteCommand.WriteResult: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTWriteResult

    func toProto(context: Serialization.Context) throws -> ProtoCRDTWriteResult {
        var proto = ProtoCRDTWriteResult()
        switch self {
        case .success:
            proto.type = .success
        case .failure(let error):
            proto.type = .failure
            proto.error = error.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTWriteResult, context: Serialization.Context) throws {
        switch proto.type {
        case .success:
            self = .success
        case .failure:
            guard proto.hasError else {
                throw SerializationError.missingField("error", type: String(describing: CRDT.Replicator.RemoteCommand.WriteResult.self))
            }
            let error = try CRDT.Replicator.RemoteCommand.WriteError(fromProto: proto.error, context: context)

            self = .failure(error)
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.WriteResult.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTWriteResult.type field.")
        }
    }
}

extension CRDT.Replicator.RemoteCommand.WriteError: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTWriteError

    func toProto(context: Serialization.Context) -> ProtoCRDTWriteError {
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

    init(fromProto proto: ProtoCRDTWriteError, context: Serialization.Context) throws {
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
    typealias ProtobufRepresentation = ProtoCRDTReadResult

    func toProto(context: Serialization.Context) throws -> ProtoCRDTReadResult {
        var proto = ProtoCRDTReadResult()
        switch self {
        case .success(let data):
            proto.type = .success
            proto.envelope = try ProtoCRDTEnvelope.serialize(context, crdt: data)
        case .failure(let error):
            proto.type = .failure
            proto.error = error.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReadResult, context: Serialization.Context) throws {
        switch proto.type {
        case .success:
            guard proto.hasEnvelope else {
                throw SerializationError.missingField("envelope", type: String(describing: CRDT.Replicator.Message.self))
            }
            let envelope = try CRDTEnvelope(fromProto: proto.envelope, context: context)

            self = .success(envelope.underlying)
        case .failure:
            guard proto.hasError else {
                throw SerializationError.missingField("error", type: String(describing: CRDT.Replicator.RemoteCommand.ReadResult.self))
            }
            let error = try CRDT.Replicator.RemoteCommand.ReadError(fromProto: proto.error, context: context)

            self = .failure(error)
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDT.Replicator.RemoteCommand.ReadResult.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTReadResult.type field.")
        }
    }
}

extension CRDT.Replicator.RemoteCommand.ReadError: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTReadError

    func toProto(context: Serialization.Context) -> ProtoCRDTReadError {
        var proto = ProtoCRDTReadError()
        switch self {
        case .notFound:
            proto.type = .notFound
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReadError, context: Serialization.Context) throws {
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
    typealias ProtobufRepresentation = ProtoCRDTDeleteResult

    func toProto(context: Serialization.Context) throws -> ProtoCRDTDeleteResult {
        var proto = ProtoCRDTDeleteResult()
        switch self {
        case .success:
            proto.type = .success
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTDeleteResult, context: Serialization.Context) throws {
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Proto CRDT Envelope extensions

extension ProtoCRDTEnvelope {
    /// Not an init to make it explicit that we perform serialization here.
    public static func serialize(_ context: Serialization.Context, crdt: StateBasedCRDT) throws -> ProtoCRDTEnvelope {
        var (manifest, bytes) = try context.serialization.serialize(crdt)
        var proto = ProtoCRDTEnvelope()
        proto.manifest = manifest.toProto()
        proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe, since we definitely read a safe amount of data here
        return proto
    }
}
