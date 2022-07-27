//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
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

/// Allows for serialization of a *single* blob at the top level.
/// Used for messages encoded using external serializers, such as protobuf, flat buffers or similar.
public class _TopLevelBytesBlobSerializer<Message: Codable>: Serializer<Message> {
    let allocator: ByteBufferAllocator

    private let context: Serialization.Context

    public init(allocator: ByteBufferAllocator, context: Serialization.Context, type: Message.Type = Message.self) {
        self.allocator = allocator
        self.context = context
    }

    override public func serialize(_ message: Message) throws -> Serialization.Buffer {
        let encoder = TopLevelBytesBlobEncoder(allocator: self.allocator) // TODO: make it not a class?
        encoder.userInfo[.actorSystemKey] = self.context.system
        encoder.userInfo[.actorSerializationContext] = self.context
        try message.encode(to: encoder)
        guard let bytes = encoder.result else {
            throw SerializationError(.unableToSerialize(hint: "Encoding result of \(TopLevelBytesBlobEncoder.self) was empty, for message: \(message)"))
        }

        traceLog_Serialization("serialized to: \(bytes)")
        return bytes
    }

    override public func deserialize(from buffer: Serialization.Buffer) throws -> Message {
        let decoder = TopLevelBytesBlobDecoder()
        decoder.userInfo[.actorSystemKey] = self.context.system
        decoder.userInfo[.actorSerializationContext] = self.context

        return try Message._decode(from: buffer, using: decoder)
    }
}
