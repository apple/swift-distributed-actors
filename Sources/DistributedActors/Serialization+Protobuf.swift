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

import NIO
import SwiftProtobuf

protocol ProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    func toProto(context: ActorSerializationContext) throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation, context: ActorSerializationContext) throws
}

internal final class ProtobufSerializer<T: ProtobufRepresentable>: Serializer<T> {
    var _serializationContext: ActorSerializationContext?
    var serializationContext: ActorSerializationContext {
        guard let context = self._serializationContext else {
            fatalError("ActorSerializationContext not available on \(self). This is a bug, please report.")
        }

        return context
    }

    let allocator: ByteBufferAllocator

    init (allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    override func serialize(message: T) throws -> ByteBuffer {
        let proto = try message.toProto(context: self.serializationContext)
        return try proto.serializedByteBuffer(allocator: self.allocator)
    }

    override func deserialize(bytes: ByteBuffer) throws -> T {
        var bytes = bytes
        let proto = try T.ProtobufRepresentation(bytes: &bytes)
        return try T(fromProto: proto, context: self.serializationContext)
    }

    override func setSerializationContext(_ context: ActorSerializationContext) {
        self._serializationContext = context
    }
}
