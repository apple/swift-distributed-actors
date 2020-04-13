//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOFoundationCompat

import Foundation // for Codable

/// Allows for serialization of messages using any compatible `Encoder` and `Decoder` pair.
///
/// Such serializer may be registered with `Serialization` and assigned either as default (see `Serialization.Settings
///
/// - Note: Take care to ensure that both "ends" (sending and receiving members of a cluster)
///   use the same encoding/decoding mechanism for a specific message.
public class JSONCodableSerializer<Message: Codable>: Serializer<Message> {
    internal let allocate: ByteBufferAllocator
    internal var encoder: JSONEncoder
    internal var decoder: JSONDecoder

    public init(allocator: ByteBufferAllocator, encoder: JSONEncoder = .init(), decoder: JSONDecoder = .init()) {
        self.allocate = allocator
        self.encoder = encoder
        self.decoder = decoder
    }

    public override func serialize(_ message: Message) throws -> ByteBuffer {
        let data = try encoder.encode(message)
        var bytes = self.allocate.buffer(capacity: data.count)
        bytes.writeBytes(data)

        traceLog_Serialization("serialized to: \(data)")
        return bytes
    }

    public override func deserialize(from bytes: ByteBuffer) throws -> Message {
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.unableToDeserialize("Could not read data! Was: \(bytes), trying to deserialize: \(Message.self)")
        }

        return try self.decoder.decode(Message.self, from: data)
    }

    public override func setSerializationContext(_ context: Serialization.Context) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }

    public override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.encoder.userInfo[key] = value
        self.decoder.userInfo[key] = value
    }
}

/// Allows for serialization of messages using any compatible `Encoder` and `Decoder` pair.
///
/// Such serializer may be registered with `Serialization` and assigned either as default (see `Serialization.Settings
///
/// - Note: Take care to ensure that both "ends" (sending and receiving members of a cluster)
///   use the same encoding/decoding mechanism for a specific message.
public class PropertyListCodableSerializer<Message: Codable>: Serializer<Message> {
    internal let allocate: ByteBufferAllocator
    internal var encoder: PropertyListEncoder
    internal var decoder: PropertyListDecoder

    public init(allocator: ByteBufferAllocator, encoder: PropertyListEncoder = .init(), decoder: PropertyListDecoder = .init()) {
        self.allocate = allocator
        self.encoder = encoder
        self.decoder = decoder
    }

    public override func serialize(_ message: Message) throws -> ByteBuffer {
        let data = try encoder.encode(message)
        var bytes = self.allocate.buffer(capacity: data.count)
        bytes.writeBytes(data)

        traceLog_Serialization("serialized to: \(data)")
        return bytes
    }

    public override func deserialize(from bytes: ByteBuffer) throws -> Message {
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.unableToDeserialize("Could not read data! Was: \(bytes), trying to deserialize: \(Message.self)")
        }

        return try self.decoder.decode(Message.self, from: data)
    }

    public override func setSerializationContext(_ context: Serialization.Context) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }

    public override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.encoder.userInfo[key] = value
        self.decoder.userInfo[key] = value
    }
}
