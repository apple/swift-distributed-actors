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

/// An envelope representing `AnyStateBasedCRDT` type such as `AnyCvRDT`, `AnyDeltaCRDT`.
///
/// Due to Swift language restriction, `CvRDT` and `DeltaCRDT` types can only be used as generic constraints. As a
/// result the type-erasing `AnyCvRDT` and `AnyDeltaCRDT` were introduced and used in CRDT replication and gossiping.
/// We have to distinguish between CvRDT and delta-CRDT in order to take advantage of optimizations offered by the
/// latter (i.e., replicate partial state or delta instead of full state).
///
/// We must also keep the underlying CRDT intact during de/serialization, and thanks to the envelope, we can do that.
/// The "boxing" serialization mechanism allows restoration of the `AnyStateBasedCRDT` instance given the underlying CRDT.
internal struct CRDTEnvelope {
    enum Boxed {
        case CvRDT(AnyCvRDT)
        case DeltaCRDT(AnyDeltaCRDT)
    }

    let serializerId: Serialization.SerializerId
    let _boxed: Boxed

    init(serializerId: Serialization.SerializerId, _ data: AnyStateBasedCRDT) {
        switch data {
        case let data as AnyCvRDT:
            self._boxed = .CvRDT(data)
        case let data as AnyDeltaCRDT:
            self._boxed = .DeltaCRDT(data)
        default:
            fatalError("Unsupported \(data)")
        }
        self.serializerId = serializerId

        traceLog_Serialization("\(self)")
    }

    var underlying: AnyStateBasedCRDT {
        switch self._boxed {
        case .CvRDT(let data):
            return data
        case .DeltaCRDT(let data):
            return data
        }
    }
}

extension CRDTEnvelope: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTEnvelope

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTEnvelope {
        var proto = ProtoCRDTEnvelope()
        switch self._boxed {
        case .CvRDT(let data):
            let (serializerId, _bytes) = try context.system.serialization.serialize(message: data.underlying, metaType: data.metaType)
            var bytes = _bytes
            proto.boxed = .anyCvrdt
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto
        case .DeltaCRDT(let data):
            let (serializerId, _bytes) = try context.system.serialization.serialize(message: data.underlying, metaType: data.metaType)
            var bytes = _bytes
            proto.boxed = .anyDeltaCrdt
            proto.serializerID = serializerId
            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
            return proto
        }
    }

    init(fromProto proto: ProtoCRDTEnvelope, context: ActorSerializationContext) throws {
        // TODO: avoid having to alloc, but deser from Data directly
        var bytes = context.allocator.buffer(capacity: proto.payload.count)
        bytes.writeBytes(proto.payload)

        let payload = try context.system.serialization.deserialize(serializerId: proto.serializerID, from: bytes)
        self.serializerId = proto.serializerID

        switch proto.boxed {
        case .anyCvrdt:
            if let anyCvRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyCvRDT.self) {
                self._boxed = .CvRDT(anyCvRDT)
            } else {
                fatalError("Unable to box [\(payload)] to [\(AnyCvRDT.self)]")
            }
        case .anyDeltaCrdt:
            if let anyDeltaCRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyDeltaCRDT.self) {
                self._boxed = .DeltaCRDT(anyDeltaCRDT)
            } else {
                fatalError("Unable to box [\(payload)] to [\(AnyDeltaCRDT.self)]")
            }
        case .unspecified:
            throw SerializationError.missingField("type", type: String(describing: CRDTEnvelope.self))
        case .UNRECOGNIZED:
            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTEnvelope.boxed field.")
        }
    }
}

extension AnyStateBasedCRDT {
    internal func asCRDTEnvelope(_ context: ActorSerializationContext) throws -> CRDTEnvelope {
        guard let serializerId = context.system.serialization.serializerIdFor(metaType: self.metaType) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "\(self.metaType)")
        }
        return CRDTEnvelope(serializerId: serializerId, self)
    }
}
