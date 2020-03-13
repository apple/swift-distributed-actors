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
//    enum Boxed {
//        case CvRDT(AnyCvRDT)
//        case DeltaCRDT(AnyDeltaCRDT)
//    }

    let manifest: Serialization.Manifest
    // let _boxed: Boxed // FIXME: won't be good...
    let data: AnyStateBasedCRDT

    init(manifest: Serialization.Manifest, _ data: AnyStateBasedCRDT) {
//        switch data {
//        case let data as AnyCvRDT:
//            self._boxed = .CvRDT(data)
//        case let data as AnyDeltaCRDT:
//            self._boxed = .DeltaCRDT(data)
//        default:
//            fatalError("Unsupported \(data)")
//        }
        self.data = data
        self.manifest = manifest

        traceLog_Serialization("\(self)")
    }

    var underlying: AnyStateBasedCRDT {
//        switch self._boxed {
//        case .CvRDT(let data):
//            return data
//        case .DeltaCRDT(let data):
//            return data
//        }
        return data
    }
}

// FIXME: Likely not well adjusted to !!!!!!
extension CRDTEnvelope: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTEnvelope

    func toProto(context: Serialization.Context) throws -> ProtoCRDTEnvelope {
        var proto = ProtoCRDTEnvelope()
        var (manifest, bytes) = try context.serialization.serialize(data.underlying)
//        switch self._boxed {
//        case .CvRDT(let data):
//            let (manifest, _bytes) = try context.system.serialization.serialize(data.underlying)
//            var bytes = _bytes
//            // proto.boxed = .anyCvrdt
//            proto.manifest = manifest.toProto()
//            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
//            return proto
//        case .DeltaCRDT(let data):
//            let (manifest, _bytes) = try context.system.serialization.serialize(data.underlying)
//            var bytes = _bytes
//            // proto.boxed = .anyDeltaCrdt
//            proto.manifest = manifest.toProto()
//            proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes
//            return proto
//        }
    }

    init(fromProto proto: ProtoCRDTEnvelope, context: Serialization.Context) throws {
        guard proto.hasManifest else {
            throw SerializationError.missingManifest(hint: "missing .manifest in: \(proto)")
        }

        let manifest = Serialization.Manifest(fromProto: proto.manifest)
        self.manifest = .init(fromProto: proto.manifest)

        var bytes = context.allocator.buffer(capacity: proto.payload.count)
        bytes.writeBytes(proto.payload)
        
        let PayloadType = try context.serialization.summonType(from: manifest)
        let deserialized = try context.serialization.deserializeAny(as: PayloadType, from: &bytes, using: manifest)

        switch deserialized {
//        case let delta as AnyDeltaCRDT:
//            self._boxed = .DeltaCRDT(delta)
//        case let data as AnyCvRDT:
//            self._boxed = .CvRDT(data)

        // public protocol CvRDT: StateBasedCRDT {
        //     func merge(Self)
        // }
        // protocol 'CvRDT' can only be used as a generic constraint because it has Self or associated type requirements
        // case let data as CvRDT:
        //    ^
        case let data as AnyStateBasedCRDT:
            fatalError("GOT StateBasedCRDT data = \(data)") // exactly right type
            self.data = data
//            self._boxed = .CvRDT(.init(data)) // , won't compile tho
//            error: protocol type 'StateBasedCRDT' cannot conform to 'CvRDT' because only concrete types can conform to protocols
//            self._boxed = .CvRDT(.init(data)) // , won't compile tho
//                ^
        default:
            throw SerializationError.unableToDeserialize(hint: """
                                                               CRDTEnvelope can only contain \(AnyDeltaCRDT.self) or \(AnyCvRDT.self). 
                                                               Deserialized unexpected type: \(String(reflecting: type(of: deserialized))), value: \(deserialized)
                                                               """)
        }

//        if let Type = PayloadType as? _DeltaCRDT.Type {
//            let payload = try context.serialization.deserialize(as: Type, from: &bytes, using: manifest)
//            let boxed = AnyDeltaCRDT(payload)
//            self._boxed = .DeltaCRDT(boxed)
////            if let anyDeltaCRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyDeltaCRDT.self) {
////                self._boxed = .DeltaCRDT(anyDeltaCRDT)
////            } else {
////                fatalError("Unable to box [\(payload)] to [\(AnyDeltaCRDT.self)]")
//        } else if let Type = PayloadType as? AnyStateBasedCRDT.Type {
//            let payload = try context.serialization.deserialize(as: Type, from: &bytes, using: manifest)
//            let boxed = AnyCvRDT(payload)
//            self._boxed = .CvRDT(payload)
//
////            if let anyCvRDT = context.box(payload, ofKnownType: type(of: payload), as: AnyCvRDT.self) {
////                self._boxed = .CvRDT(anyCvRDT)
////            } else {
////                fatalError("Unable to box [\(payload)] to [\(AnyCvRDT.self)]")
////            }
//        } else {
////        case .unspecified:
//            throw SerializationError.missingField("type", type: String(describing: CRDTEnvelope.self))
////        case .UNRECOGNIZED:
////            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTEnvelope.boxed field.")
//        }
    }
}

extension AnyStateBasedCRDT {

    // TODO: cleanup of this, do we need it like that?
    internal func wrapWithEnvelope(_ context: Serialization.Context) throws -> CRDTEnvelope {
        let manifest = try context.serialization.outboundManifest(Self.self)
        return CRDTEnvelope(manifest: manifest, self)
    }
}
