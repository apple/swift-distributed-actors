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

/// An envelope representing `AnyStateBasedCRDT` while carrying information if it was the full CRDT or "only" a delta.
///
/// E.g. a `CRDT.GCounter`'s delta type is also a `CRDT.GCounter`, however when gossiping or writing information,
/// we may want to keep the information if the piece of data is a delta update, or the full state of the CRDT - and thanks to the envelope, we can.
struct CRDTEnvelope {
    enum Storage {
        case crdt(AnyCvRDT)
        case delta(AnyDeltaCRDT)
    }

    let serializerId: Serialization.SerializerId
    let _storage: Storage

    init(serializerId: Serialization.SerializerId, _ data: AnyStateBasedCRDT) {
        switch data {
        case let data as AnyCvRDT:
            self._storage = .crdt(data)
        case let data as AnyDeltaCRDT:
            self._storage = .delta(data)
        default:
            fatalError("Unsupported \(data)")
        }
        self.serializerId = serializerId

        traceLog_Serialization("\(self)")
    }

    var underlying: AnyStateBasedCRDT {
        switch self._storage {
        case .crdt(let dataType):
            return dataType
        case .delta(let delta):
            return delta
        }
    }
}

extension CRDTEnvelope: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTEnvelope

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTEnvelope {
        var proto = ProtoCRDTEnvelope()
        switch self._storage {
        case .crdt(let data):
            fatalError()
            var (serializerId, _bytes) = try context.system.serialization.serialize(message: data.underlying, metaType: data.metaType)
            var bytes = _bytes
            proto.type = .crdt
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto

        case .delta(let delta):
            var (serializerId, _bytes) = try context.system.serialization.serialize(message: delta.underlying, metaType: delta.metaType)
            var bytes = _bytes
            proto.type = .delta
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto
        }
    }

    public init(fromProto proto: ProtoCRDTEnvelope, context: ActorSerializationContext) throws {
        var bytes = context.allocator.buffer(capacity: proto.payload.count)
        bytes.writeBytes(proto.payload)

        let payload = try context.system.serialization.deserialize(serializerId: proto.serializerID, from: bytes)
        self.serializerId = proto.serializerID

        switch proto.type {
        case .crdt:
            if let anyCRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyCvRDT.self) {
                self._storage = .crdt(anyCRDT)
            } else {
                fatalError("Unable to box \(payload) to \(AnyCvRDT.self)")
            }
        case .delta:
            if let anyDelta = context.box(payload, ofKnownType: type(of: payload), as: AnyDeltaCRDT.self) {
                self._storage = .delta(anyDelta)
            } else {
                fatalError("Unable to box \(payload) to \(AnyDeltaCRDT.self)")
            }
        case .UNRECOGNIZED:
            fatalError() // FIXME: remove this case; we always will be a delta or a crdt here?
        }
    }
}
