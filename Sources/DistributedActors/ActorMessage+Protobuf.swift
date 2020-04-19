//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import NIO
import protocol Swift.Decoder // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder // to prevent shadowing by the ones in SwiftProtobuf
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

public protocol AnyProtobufRepresentable: ActorMessage {}

public protocol AnyPublicProtobufRepresentable: AnyProtobufRepresentable {}

/// A protocol that facilitates conversion between Swift and protobuf messages.
///
/// - SeeAlso: `ActorMessage`
public protocol ProtobufRepresentable: AnyPublicProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    /// Convert this `ProtobufRepresentable` instance to an instance of type `ProtobufRepresentation`.
    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation

    /// Initialize a `ProtobufRepresentable` instance from the given `ProtobufRepresentation` instance.
    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws
}

// Implementation note:
// This conformance is a bit weird, and it is not usually going to be invoked through Codable
// however it could, so we allow for this use case.
extension ProtobufRepresentable {
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
        let data = try proto.serializedData()

        try container.encode(data)
    }
}

/// This protocol is for internal protobuf-serializable messages only.
///
/// We need a protocol separate from `ProtobufRepresentable` because otherwise we would be forced to make internal types public.
internal protocol InternalProtobufRepresentable: AnyProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    init(from decoder: Decoder) throws
    func encode(to encoder: Encoder) throws

    func toProto(context: Serialization.Context) throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws
}

// Implementation note:
// This conformance is a bit weird, and it is not usually going to be invoked through Codable
// however it could, so we allow for this use case.
extension InternalProtobufRepresentable {
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
// MARK: Codable -- ProtobufRepresentable --> Protocol Buffers

extension InternalProtobufRepresentable where Self: ActorMessage {
    init(context: Serialization.Context, from buffer: Serialization.Buffer, using manifest: Serialization.Manifest) throws {
        let data: Data
        switch buffer {
        case .data(let d):
            data = d
        case .nioByteBuffer(var buffer):
            data = buffer.readData(length: buffer.readableBytes)! // safe since using readableBytes
        }
        let proto = try ProtobufRepresentation(serializedData: data)
        try self.init(fromProto: proto, context: context)
    }

    func serialize(context: Serialization.Context) throws -> Serialization.Buffer {
        try .data(self.toProto(context: context).serializedData())
    }
}

extension ProtobufRepresentable where Self: ActorMessage {
    public init(context: Serialization.Context, from buffer: Serialization.Buffer, using manifest: Serialization.Manifest) throws {
        let data: Data
        switch buffer {
        case .data(let d):
            data = d
        case .nioByteBuffer(var buffer):
            data = buffer.readData(length: buffer.readableBytes)! // safe since using readableBytes
        }
        let proto = try ProtobufRepresentation(serializedData: data)
        try self.init(fromProto: proto, context: context)
    }

    public func serialize(context: Serialization.Context) throws -> Serialization.Buffer {
        try .data(self.toProto(context: context).serializedData())
    }
}
