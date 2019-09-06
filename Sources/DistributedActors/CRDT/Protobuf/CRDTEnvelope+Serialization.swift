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

/// An envelope representing `AnyStateBasedCRDT` while carrying information if it was the full CRDT or "only" a delta.
///
/// E.g. a `CRDT.GCounter`'s delta type is also a `CRDT.GCounter`, however when gossiping or writing information,
/// we may want to keep the information if the piece of data is a delta update, or the full state of the CRDT - and thanks to the envelope, we can.
struct CRDTEnvelope {
    enum Boxed {
        case crdt(AnyCvRDT)
        case delta(AnyDeltaCRDT)
    }

    let serializerId: Serialization.SerializerId
    let _boxed: Boxed

    init(serializerId: Serialization.SerializerId, _ data: AnyStateBasedCRDT) {
        switch data {
        case let data as AnyCvRDT:
            self._boxed = .crdt(data)
        case let data as AnyDeltaCRDT:
            self._boxed = .delta(data)
        default:
            fatalError("Unsupported \(data)")
        }
        self.serializerId = serializerId

        traceLog_Serialization("\(self)")
    }

    var underlying: AnyStateBasedCRDT {
        switch self._boxed {
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
        switch self._boxed {
        case .crdt(let data):
            let (serializerId, _bytes) = try context.system.serialization.serialize(message: data.underlying, metaType: data.metaType)
            var bytes = _bytes
            proto.boxed = .anyCvrdt
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto

        case .delta(let delta):
            let (serializerId, _bytes) = try context.system.serialization.serialize(message: delta.underlying, metaType: delta.metaType)
            var bytes = _bytes
            proto.boxed = .anyDeltaCrdt
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto
        }
    }

    public init(fromProto proto: ProtoCRDTEnvelope, context: ActorSerializationContext) throws {
        // TODO: avoid having to alloc, but deser from Data directly
        var bytes = context.allocator.buffer(capacity: proto.payload.count)
        bytes.writeBytes(proto.payload)

        let payload = try context.system.serialization.deserialize(serializerId: proto.serializerID, from: bytes)
        self.serializerId = proto.serializerID

        switch proto.boxed {
        case .anyCvrdt:
            if let anyCRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyCvRDT.self) {
                self._boxed = .crdt(anyCRDT)
            } else {
                fatalError("Unable to box [\(payload)] to [\(AnyCvRDT.self)]")
            }
        case .anyDeltaCrdt:
            if let anyDelta = context.box(payload, ofKnownType: type(of: payload), as: AnyDeltaCRDT.self) {
                self._boxed = .delta(anyDelta)
            } else {
                fatalError("Unable to box [\(payload)] to [\(AnyDeltaCRDT.self)]")
            }
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTEnvelope.boxed field.")
        }
    }
}
