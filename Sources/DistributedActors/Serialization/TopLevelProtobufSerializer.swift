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

internal class _TopLevel_ProtobufSerializer<Message>: Serializer<Message> {
    let allocator: ByteBufferAllocator
    private let context: Serialization.Context

    public init(allocator: ByteBufferAllocator, context: Serialization.Context) {
        self.allocator = allocator
        self.context = context
    }

    override public func serialize(_ message: Message) throws -> Serialization.Buffer {
        guard let repr = message as? _AnyProtobufRepresentable else {
            throw SerializationError.unableToSerialize(hint: "Can only serialize Any_InternalProtobufRepresentable types, was: \(String(reflecting: Message.self))")
        }

        let encoder = TopLevelProtobufBlobEncoder(allocator: self.allocator)
        encoder.userInfo[.actorSystemKey] = self.context.system
        encoder.userInfo[.actorSerializationContext] = self.context
        try repr.encode(to: encoder)

        guard let buffer = encoder.result else {
            throw SerializationError.unableToSerialize(hint: "Encoding result of \(TopLevelBytesBlobEncoder.self) was empty, for message: \(message)")
        }

        traceLog_Serialization("serialized to: \(buffer)")
        return buffer
    }

    override public func deserialize(from buffer: Serialization.Buffer) throws -> Message {
        guard let ProtoType = Message.self as? _AnyProtobufRepresentable.Type else {
            throw SerializationError.unableToDeserialize(hint: "Can only deserialize Any_InternalProtobufRepresentable but was \(Message.self)")
        }

        let decoder = TopLevelProtobufBlobDecoder()
        decoder.userInfo[.actorSystemKey] = self.context.system
        decoder.userInfo[.actorSerializationContext] = self.context

        return try ProtoType.init(from: decoder) as! Message // explicit .init() is required here (!)
    }

    override public func setSerializationContext(_ context: Serialization.Context) {
        // self.context = context
    }

    override public func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {}
}
