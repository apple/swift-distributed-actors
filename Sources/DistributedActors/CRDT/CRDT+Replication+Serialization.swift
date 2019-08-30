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

// We cannot have `CvRDT` protocol inherit `ProtobufRepresentable` protocol because that would
// force custom CRDTs to use protobuf for serialization.

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Wrapped CvRDT and DeltaCRDT serializers

internal final class AnyWrappedCvRDTSerializer<T: CvRDT>: Serializer<AnyCvRDT> {
    private let serializer: Serializer<T>

    init(_ serializer: Serializer<T>) {
        self.serializer = serializer
    }

    override func serialize(message: AnyCvRDT) throws -> ByteBuffer {
        return try self.serializer.trySerialize(message.underlying)
    }

    override func deserialize(bytes: ByteBuffer) throws -> AnyCvRDT {
        let data = try serializer.deserialize(bytes: bytes)
        return data.asAnyCvRDT
    }
}

internal final class AnyWrappedDeltaCRDTSerializer<T: DeltaCRDT>: Serializer<AnyDeltaCRDT> {
    private let serializer: Serializer<T>

    init(_ serializer: Serializer<T>) {
        self.serializer = serializer
    }

    override func serialize(message: AnyDeltaCRDT) throws -> ByteBuffer {
        return try self.serializer.trySerialize(message.underlying)
    }

    override func deserialize(bytes: ByteBuffer) throws -> AnyDeltaCRDT {
        let data = try serializer.deserialize(bytes: bytes)
        return data.asAnyDeltaCRDT
    }
}

internal extension Serializer where T: CvRDT {
    var asAnyWrappedCvRDTSerializer: Serializer<AnyCvRDT> {
        return AnyWrappedCvRDTSerializer<T>(self)
    }
}

internal extension Serializer where T: DeltaCRDT {
    var asAnyWrappedDeltaCRDTSerializer: Serializer<AnyDeltaCRDT> {
        return AnyWrappedDeltaCRDTSerializer<T>(self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization extensions

internal struct CRDTSerialization {
    // Key is the CRDT's serializer id
    // Value is wrapped CRDT serializer that converts CRDT to AnyCvRDT/AnyDeltaCRDT
    var anySerializers: [Serialization.SerializerId: AnySerializer] = [:]

    init() {}
}

extension Serialization {
    internal mutating func registerCvRDTSerializer<T: CvRDT>(_ context: ActorSerializationContext,
                                                             serializer: Serializer<T>,
                                                             for type: T.Type,
                                                             underId id: SerializerId) {
        self.registerSystemSerializer(context, serializer: serializer, for: type, underId: id)
        self.crdt.anySerializers[id] = BoxedAnySerializer(serializer.asAnyWrappedCvRDTSerializer)
    }

    internal mutating func registerDeltaCRDTSerializer<T: DeltaCRDT>(_ context: ActorSerializationContext,
                                                                     serializer: Serializer<T>,
                                                                     for type: T.Type,
                                                                     underId id: SerializerId) {
        self.registerSystemSerializer(context, serializer: serializer, for: type, underId: id)
        self.crdt.anySerializers[id] = BoxedAnySerializer(serializer.asAnyWrappedDeltaCRDTSerializer)
    }

    internal func anyStateBasedCRDTSerializer(for id: SerializerId) -> AnySerializer? {
        return self.crdt.anySerializers[id]
    }
}
