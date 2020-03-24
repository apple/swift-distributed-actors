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

public class TopLevelProtobufSerializer<Message>: Serializer<Message> {
    let allocator: ByteBufferAllocator
    private let context: Serialization.Context

    public init(allocator: ByteBufferAllocator, context: Serialization.Context) {
        self.allocator = allocator
        self.context = context
    }

    public override func serialize(_ message: Message) throws -> ByteBuffer {
        guard let repr = message as? AnyProtobufRepresentable else {
            throw SerializationError.unableToSerialize(hint: "Can only serialize AnyInternalProtobufRepresentable types, was: \(String(reflecting: Message.self))")
        }

        let encoder = TopLevelProtobufBlobEncoder(allocator: self.allocator)
        encoder.userInfo[.actorSerializationContext] = self.context
        try repr.encode(to: encoder)

        guard let bytes = encoder.result else {
            throw SerializationError.unableToSerialize(hint: "Encoding result of \(TopLevelBytesBlobEncoder.self) was empty, for message: \(message)")
        }

        traceLog_Serialization("serialized to: \(bytes)")
        return bytes
    }

    public override func deserialize(from bytes: ByteBuffer) throws -> Message {
        guard let ProtoType = Message.self as? AnyProtobufRepresentable.Type else {
            throw SerializationError.unableToDeserialize(hint: "Can only deserialize AnyInternalProtobufRepresentable but was \(Message.self)")
        }

        let decoder = TopLevelProtobufBlobDecoder()
        decoder.userInfo[.actorSerializationContext] = self.context

        return try ProtoType.init(from: decoder) as! Message // explicit .init() is required here (!)
    }

    public override func setSerializationContext(_ context: Serialization.Context) {
        // self.context = context
    }

    public override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {}
}
