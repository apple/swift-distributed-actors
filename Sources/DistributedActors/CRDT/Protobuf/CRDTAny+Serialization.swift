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

// 1. Each CRDT should have a serializer (e.g. for GCounter it's ProtobufSerializer<GCounter>()).
// 2. Register the CRDT serializer.
//  - Can add convenience method to Serialization in the future (e.g., `registerCvRDTSerializer`).
//  - Need to distinguish between CvRDT and DeltaCRDT because their wrapped serializer is different.
// 3. Behind the scenes we create a wrapper serializer (e.g., AnyWrappedCvRDTSerializer) that can deserialize CRDT into AnyCvRDT/AnyDeltaCRDT.
//  - See CRDT+Replication+Serialization.
// 4. AnyCvRDT/AnyDeltaCRDT conform to InternalProtobufRepresentable
//  a. toProto: Use context and metaType to lookup underlying's serializer
//    - Call its `serialize` to get payload bytes
//    - Include serializer id
//  b. init(fromProto): Use serialize id to look up wrapped serializer (3)
//    - Deserialize underlying CRDT into AnyCvRDT/AnyDeltaCRDT (type `Any`)
//    - Cast to AnyCvRDT/AnyDeltaCRDT
// 5. Register InternalProtobufSerializer for AnyCvRDT/AnyDeltaCRDT
// 6. Local send AnyCvRDT/AnyDeltaCRDT to remote - will be (de)serialized properly

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyCvRDT

extension AnyCvRDT: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoAnyCvRDT

    func toProto(context: ActorSerializationContext) throws -> ProtoAnyCvRDT {
        // Serialize the underlying CRDT using its registered serializer
        var (serializerId, byteBuffer) = try context.system.serialization.serialize(message: self.underlying, metaType: self.metaType)

        var proto = ProtoAnyCvRDT()
        // Save the underlying CRDT's serializer id so we can deserialize underlying later
        proto.underlyingSerializerID = serializerId
        proto.underlyingBytes = byteBuffer.readData(length: byteBuffer.readableBytes)! // !-safe because we read exactly the number of readable bytes
        return proto
    }

    init(fromProto proto: ProtoAnyCvRDT, context: ActorSerializationContext) throws {
        guard proto.underlyingSerializerID != 0 else {
            throw SerializationError.missingField("underlyingSerializerID", type: String(describing: AnyCvRDT.self))
        }
        guard let serializer = context.system.serialization.anyStateBasedCRDTSerializer(for: proto.underlyingSerializerID) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "AnyWrappedCvRDTSerializer for id \(proto.underlyingSerializerID) for found")
        }

        var underlyingBuffer = context.allocator.buffer(capacity: proto.underlyingBytes.count)
        underlyingBuffer.writeBytes(proto.underlyingBytes)

        // Deserialize the underlying CRDT from the proto
        let deserialized = try serializer.tryDeserialize(underlyingBuffer)
        guard let anyCvRDT = deserialized as? AnyCvRDT else {
            throw SerializationError.notAbleToDeserialize(hint: "Not AnyCvRDT")
        }

        self = anyCvRDT
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyDeltaCRDT

extension AnyDeltaCRDT: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoAnyDeltaCRDT

    func toProto(context: ActorSerializationContext) throws -> ProtoAnyDeltaCRDT {
        // Serialize the underlying CRDT using its registered serializer
        var (serializerId, byteBuffer) = try context.system.serialization.serialize(message: self.underlying, metaType: self.metaType)

        var proto = ProtoAnyDeltaCRDT()
        // Save the underlying CRDT's serializer id so we can deserialize underlying later
        proto.underlyingSerializerID = serializerId
        proto.underlyingBytes = byteBuffer.readData(length: byteBuffer.readableBytes)! // !-safe because we read exactly the number of readable bytes
        return proto
    }

    init(fromProto proto: ProtoAnyDeltaCRDT, context: ActorSerializationContext) throws {
        guard proto.underlyingSerializerID != 0 else {
            throw SerializationError.missingField("underlyingSerializerID", type: String(describing: AnyDeltaCRDT.self))
        }
        guard let serializer = context.system.serialization.anyStateBasedCRDTSerializer(for: proto.underlyingSerializerID) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "AnyWrappedDeltaCRDTSerializer for id \(proto.underlyingSerializerID) for found")
        }

        var underlyingBuffer = context.allocator.buffer(capacity: proto.underlyingBytes.count)
        underlyingBuffer.writeBytes(proto.underlyingBytes)

        // Deserialize the underlying CRDT from the proto
        let deserialized = try serializer.tryDeserialize(underlyingBuffer)
        guard let anyDeltaCRDT = deserialized as? AnyDeltaCRDT else {
            throw SerializationError.notAbleToDeserialize(hint: "Not AnyDeltaCRDT")
        }

        self = anyDeltaCRDT
    }
}
