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

extension CRDT {
    /// An envelope representing `AnyStateBasedCRDT` type such as `AnyCvRDT`, `DeltaCRDTBox`.
    ///
    /// Due to Swift language restriction, `CvRDT` and `DeltaCRDT` types can only be used as generic constraints. As a
    /// result the type-erasing `AnyCvRDT` and `DeltaCRDTBox` were introduced and used in CRDT replication and gossiping.
    /// We have to distinguish between CvRDT and delta-CRDT in order to take advantage of optimizations offered by the
    /// latter (i.e., replicate partial state or delta instead of full state).
    ///
    /// We must also keep the underlying CRDT intact during de/serialization, and thanks to the envelope, we can do that.
    /// The "boxing" serialization mechanism allows restoration of the `AnyStateBasedCRDT` instance given the underlying CRDT.
    internal struct Envelope {

        let manifest: Serialization.Manifest
        let data: StateBasedCRDT

        init(manifest: Serialization.Manifest, _ data: StateBasedCRDT) {
            self.data = data
            self.manifest = manifest
        }
    }
}

extension CRDT.Envelope: InternalProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoCRDTEnvelope

    func toProto(context: Serialization.Context) throws -> ProtoCRDTEnvelope {
        var proto = ProtoCRDTEnvelope()
        var (manifest, bytes) = try context.serialization.serialize(self.data)
        pprint("Serialize: manifest: \(manifest)")
        proto.manifest = try manifest.toProto(context: context)
        proto.payload = bytes.readData(length: bytes.readableBytes)! // !-safe, since we know exactly how many bytes to read here
        return proto
    }

    init(fromProto proto: ProtoCRDTEnvelope, context: Serialization.Context) throws {
        guard proto.hasManifest else {
            throw SerializationError.missingManifest(hint: "missing .manifest in: \(proto)")
        }

        let manifest = try Serialization.Manifest(fromProto: proto.manifest, context: context)
        self.manifest = manifest

        var bytes = context.allocator.buffer(capacity: proto.payload.count)
        bytes.writeBytes(proto.payload)

        let deserialized = try context.serialization.deserializeAny(from: &bytes, using: manifest)

        switch deserialized {
//        case let delta as DeltaCRDTBox:
//            self._boxed = .DeltaCRDT(delta)
//        case let data as AnyCvRDT:
//            self._boxed = .CvRDT(data)

        // public protocol CvRDT: StateBasedCRDT {
        //     func merge(Self)
        // }
        // protocol 'CvRDT' can only be used as a generic constraint because it has Self or associated type requirements
        // case let data as CvRDT:
        //    ^
        case let data as StateBasedCRDT:
            self.data = data
        default:
            throw SerializationError.unableToDeserialize(
                hint:
                """
                CRDT.Envelope can only contain StateBasedCRDT. \
                Deserialized unexpected type: \(String(reflecting: type(of: deserialized))), value: \(deserialized)
                """
            )
        }

//        if let Type = PayloadType as? _DeltaCRDT.Type {
//            let payload = try context.serialization.deserialize(as: Type, from: &bytes, using: manifest)
//            let boxed = DeltaCRDTBox(payload)
//            self._boxed = .DeltaCRDT(boxed)
        ////            if let DeltaCRDTBox = context.box(payload, ofKnownType: type(of: payload), as: DeltaCRDTBox.self) {
        ////                self._boxed = .DeltaCRDT(DeltaCRDTBox)
        ////            } else {
        ////                fatalError("Unable to box [\(payload)] to [\(DeltaCRDTBox.self)]")
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
//            throw SerializationError.missingField("type", type: String(describing: CRDT.Envelope.self))
        ////        case .UNRECOGNIZED:
        ////            throw SerializationError.notAbleToDeserialize(hint: "UNRECOGNIZED value in ProtoCRDTEnvelope.boxed field.")
//        }
    }
}

// extension AnyStateBasedCRDT {
//
//    // TODO: cleanup of this, do we need it like that?
//    internal func wrapWithEnvelope(_ context: Serialization.Context) throws -> CRDT.Envelope {
//        let manifest = try context.serialization.outboundManifest(Self.self)
//        return CRDT.Envelope(manifest: manifest, self)
//    }
// }
