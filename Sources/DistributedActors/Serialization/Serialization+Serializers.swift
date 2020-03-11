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

import CDistributedActorsMailbox
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializer

/// Kind of like coder / encoder, we'll provide bridges for it
// TODO: Document since users need to implement these
open class Serializer<Message> {
    public init() {}

    open func serialize(_ message: Message) throws -> ByteBuffer {
        undefined()
    }

    // TODO: does this stay like this?
    open func deserialize(from bytes: ByteBuffer) throws -> Message {
        undefined()
    }

    /// Invoked _once_ by `Serialization` during system startup, providing additional context bound to
    /// the given `ActorSystem` that enables certain system specific serialization operations, such as
    /// looking up actors.
    open func setSerializationContext(_: ActorSerializationContext) {
        // nothing by default, implementations may choose to not care
    }

    open func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        // nothing by default, implementations may choose to not care
    }
}

extension Serializer: AnySerializer {
    public func _asSerializerOf<M>(_: M.Type) -> Serializer<M> {
        return self as! Serializer<M>
    }

    public func trySerialize(_ message: Any) throws -> ByteBuffer {
        guard let _message = message as? Message else {
            throw SerializationError.wrongSerializer(
                hint: """
                Attempted to serialize message type [\(String(reflecting: type(of: message)))] \
                as [\(String(reflecting: Message.self))], which do not match! Serializer: [\(self)]
                """
            )
        }

        return try self.serialize(_message)
    }

    // FIXME: this is evil?
    public func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        try self.deserialize(from: bytes)
    }

    public var asAnySerializer: AnySerializer {
        BoxedAnySerializer(self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializers: AnySerializer

public protocol AnySerializer {
    func _asSerializerOf<M>(_ type: M.Type) throws -> Serializer<M>

    func trySerialize(_ message: Any) throws -> ByteBuffer
    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?)
    func setSerializationContext(_ context: ActorSerializationContext)
}

internal struct BoxedAnySerializer: AnySerializer {
    private let serializer: AnySerializer

    init<Serializer: AnySerializer>(_ serializer: Serializer) {
        self.serializer = serializer
    }

    func _asSerializerOf<M>(_: M.Type) throws -> Serializer<M> {
        if let wellTypedSerializer = self.serializer as? Serializer<M> {
            return wellTypedSerializer
        } else {
            throw SerializationError.wrongSerializer(hint: "Cannot cast \(self.serializer) to \(String(reflecting: Serializer<M>.self))")
        }
    }

    func setSerializationContext(_ context: ActorSerializationContext) {
        self.serializer.setSerializationContext(context)
    }

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.serializer.setUserInfo(key: key, value: value)
    }

    func trySerialize(_ message: Any) throws -> ByteBuffer {
        try self.serializer.trySerialize(message)
    }

    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        try self.serializer.tryDeserialize(bytes)
    }
}

public enum SerializationError: Error {
    // --- registration errors ---
    case alreadyDefined(hint: String, serializerID: Serialization.SerializerID, serializer: AnySerializer?)

    // --- lookup errors ---
    case noSerializerKeyAvailableFor(hint: String)
    case noSerializerRegisteredFor(hint: String, manifest: Serialization.Manifest?)
    case notAbleToDeserialize(hint: String)
    case wrongSerializer(hint: String)

    // --- format errors ---
    case missingField(String, type: String)
    case emptyRepeatedField(String)

    case unknownEnumValue(Int)

    // --- illegal errors ---
    case mayNeverBeSerialized(type: String)

    static func alreadyDefined<T>(type: T.Type, serializerID: Serialization.SerializerID, serializer: AnySerializer?) -> SerializationError {
        .alreadyDefined(hint: String(reflecting: type), serializerID: serializerID, serializer: serializer)
    }

//    static func noSerializerRegisteredFor(message: Any, meta: AnyMetaType) -> SerializationError {
//        return .noSerializerKeyAvailableFor(hint: "\(String(reflecting: type(of: message))), using meta type key: \(meta)")
//    }
}
