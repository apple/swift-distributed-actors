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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

/// A protocol that facilitates conversion between Swift and protobuf messages.
///
/// - SeeAlso: Serialization.registerProtobufRepresentable
public protocol ProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    func toProto(context: ActorSerializationContext) throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation, context: ActorSerializationContext) throws
}

/// This protocol is for internal protobuf-serializable messages only.
///
/// We need a protocol separate from `ProtobufRepresentable` because otherwise we would be forced to
/// make internal types public.
internal protocol InternalProtobufRepresentable {
    associatedtype InternalProtobufRepresentation: SwiftProtobuf.Message

    func toProto(context: ActorSerializationContext) throws -> InternalProtobufRepresentation
    init(fromProto proto: InternalProtobufRepresentation, context: ActorSerializationContext) throws
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf serializers

/// Base protobuf serializer containing common logic, customizable by subclass.
open class BaseProtobufSerializer<Message, ProtobufMessage: SwiftProtobuf.Message>: Serializer<Message> {
    var _serializationContext: ActorSerializationContext?
    var serializationContext: ActorSerializationContext {
        guard let context = self._serializationContext else {
            fatalError("ActorSerializationContext not available on \(self). This is a bug, please report.")
        }

        return context
    }

    let allocator: ByteBufferAllocator

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    open override func serialize(message: Message) throws -> ByteBuffer {
        let proto = try self.toProto(message, context: self.serializationContext)
        return try proto.serializedByteBuffer(allocator: self.allocator)
    }

    open override func deserialize(bytes: ByteBuffer) throws -> Message {
        var bytes = bytes
        let proto = try ProtobufMessage(bytes: &bytes)
        return try self.fromProto(proto, context: self.serializationContext)
    }

    // To be implemented by subclass
    open func toProto(_ message: Message, context: ActorSerializationContext) throws -> ProtobufMessage {
        return undefined()
    }

    // To be implemented by subclass
    open func fromProto(_ proto: ProtobufMessage, context: ActorSerializationContext) throws -> Message {
        return undefined()
    }

    open override func setSerializationContext(_ context: ActorSerializationContext) {
        self._serializationContext = context
    }
}

/// Protobuf serializer for user-defined protobuf messages.
public final class ProtobufSerializer<T: ProtobufRepresentable>: BaseProtobufSerializer<T, T.ProtobufRepresentation> {
    public override func toProto(_ message: T, context: ActorSerializationContext) throws -> T.ProtobufRepresentation {
        return try message.toProto(context: self.serializationContext)
    }

    public override func fromProto(_ proto: T.ProtobufRepresentation, context: ActorSerializationContext) throws -> T {
        return try T(fromProto: proto, context: self.serializationContext)
    }
}

/// Protobuf serializer for internal protobuf messages only.
internal final class InternalProtobufSerializer<T: InternalProtobufRepresentable>: BaseProtobufSerializer<T, T.InternalProtobufRepresentation> {
    public override func toProto(_ message: T, context: ActorSerializationContext) throws -> T.InternalProtobufRepresentation {
        return try message.toProto(context: self.serializationContext)
    }

    public override func fromProto(_ proto: T.InternalProtobufRepresentation, context: ActorSerializationContext) throws -> T {
        return try T(fromProto: proto, context: self.serializationContext)
    }
}
