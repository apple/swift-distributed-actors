//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import SwiftProtobuf

import struct Foundation.Data
import protocol Swift.Decoder  // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder  // to prevent shadowing by the ones in SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

public protocol _AnyProtobufRepresentable: Codable, SerializationRepresentable {}

extension _AnyProtobufRepresentable {
    public static var defaultSerializerID: Serialization.SerializerID? {
        ._ProtobufRepresentable
    }
}

public protocol _AnyPublicProtobufRepresentable: _AnyProtobufRepresentable {}

/// A protocol that facilitates conversion between Swift and protobuf messages.
public protocol _ProtobufRepresentable: _AnyPublicProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    /// Convert this `_ProtobufRepresentable` instance to an instance of type `ProtobufRepresentation`.
    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation

    /// Initialize a `_ProtobufRepresentable` instance from the given `ProtobufRepresentation` instance.
    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws
}

// Implementation note:
// This conformance is a bit weird, and it is not usually going to be invoked through Codable
// however it could, so we allow for this use case.
extension _ProtobufRepresentable {
    public init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let container = try decoder.singleValueContainer()

        let data: Data = try container.decode(Data.self)
        let proto = try ProtobufRepresentation(serializedData: data)

        try self.init(fromProto: proto, context: context)
    }

    public func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.singleValueContainer()

        let proto = try self.toProto(context: context)
        // TODO: Thought; we could detect if we're nested in a top-level JSON that we should encode as json perhaps, since proto can do this?
        let data = try proto.serializedData()

        try container.encode(data)
    }
}

/// This protocol is for internal protobuf-serializable messages only.
///
/// We need a protocol separate from `_ProtobufRepresentable` because otherwise we would be forced to make internal types public.
internal protocol _InternalProtobufRepresentable: _AnyProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    init(from decoder: Decoder) throws
    func encode(to encoder: Encoder) throws

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws
}

// Implementation note:
// This conformance is a bit weird, and it is not usually going to be invoked through Codable
// however it could, so we allow for this use case.
extension _InternalProtobufRepresentable {
    init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let container = try decoder.singleValueContainer()

        let data: Data = try container.decode(Data.self)
        let proto = try ProtobufRepresentation(serializedData: data)

        try self.init(fromProto: proto, context: context)
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.singleValueContainer()

        let proto = try self.toProto(context: context)
        let data = try proto.serializedData()

        try container.encode(data)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable -- _ProtobufRepresentable --> Protocol Buffers

extension _InternalProtobufRepresentable {
    init(
        context: Serialization.Context,
        from buffer: Serialization.Buffer,
        using manifest: Serialization.Manifest
    ) throws {
        let proto = try ProtobufRepresentation(serializedData: buffer.readData())
        try self.init(fromProto: proto, context: context)
    }

    func serialize(context: Serialization.Context) throws -> Serialization.Buffer {
        try .data(self.toProto(context: context).serializedData())
    }
}

extension _ProtobufRepresentable {
    public init(
        context: Serialization.Context,
        from buffer: Serialization.Buffer,
        using manifest: Serialization.Manifest
    ) throws {
        let proto = try ProtobufRepresentation(serializedData: buffer.readData())
        try self.init(fromProto: proto, context: context)
    }

    public func serialize(context: Serialization.Context) throws -> Serialization.Buffer {
        try .data(self.toProto(context: context).serializedData())
    }
}
