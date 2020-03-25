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
// MARK: Protobuf serializers

/// Base protobuf serializer containing common logic, customizable by subclass.
open class BaseProtobufSerializer<Message, ProtobufMessage: SwiftProtobuf.Message>: Serializer<Message> {
    var _serializationContext: Serialization.Context?
    var serializationContext: Serialization.Context {
        guard let context = self._serializationContext else {
            fatalError("Serialization.Context not available on \(self). This is a bug, please report.")
        }

        return context
    }

    let allocator: ByteBufferAllocator

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    open override func serialize(_ message: Message) throws -> ByteBuffer {
        let proto = try self.toProto(message, context: self.serializationContext)
        return try proto.serializedByteBuffer(allocator: self.allocator)
    }

    open override func deserialize(from bytes: ByteBuffer) throws -> Message {
        var bytes = bytes
        let proto = try ProtobufMessage(buffer: &bytes)
        return try self.fromProto(proto, context: self.serializationContext)
    }

    // To be implemented by subclass
    open func toProto(_ message: Message, context: Serialization.Context) throws -> ProtobufMessage {
        return undefined()
    }

    // To be implemented by subclass
    open func fromProto(_ proto: ProtobufMessage, context: Serialization.Context) throws -> Message {
        return undefined()
    }

    open override func setSerializationContext(_ context: Serialization.Context) {
        self._serializationContext = context
    }
}

/// Protobuf serializer for user-defined protobuf messages.
public final class ProtobufSerializer<T: ProtobufRepresentable>: BaseProtobufSerializer<T, T.ProtobufRepresentation> {
    public override func toProto(_ message: T, context: Serialization.Context) throws -> T.ProtobufRepresentation {
        return try message.toProto(context: self.serializationContext)
    }

    public override func fromProto(_ proto: T.ProtobufRepresentation, context: Serialization.Context) throws -> T {
        return try T(fromProto: proto, context: self.serializationContext)
    }
}

/// Protobuf serializer for internal protobuf messages only.
internal final class InternalProtobufSerializer<T: InternalProtobufRepresentable>: BaseProtobufSerializer<T, T.ProtobufRepresentation> {
    public override func toProto(_ message: T, context: Serialization.Context) throws -> T.ProtobufRepresentation {
        return try message.toProto(context: self.serializationContext)
    }

    public override func fromProto(_ proto: T.ProtobufRepresentation, context: Serialization.Context) throws -> T {
        return try T(fromProto: proto, context: self.serializationContext)
    }
}
