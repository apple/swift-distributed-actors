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

    open func serialize(_ message: Message) throws -> Serialization.Buffer {
        _undefined()
    }

    // TODO: does this stay like this?
    open func deserialize(from buffer: Serialization.Buffer) throws -> Message {
        _undefined()
    }

    /// Invoked _once_ by `Serialization` during system startup, providing additional context bound to
    /// the given `ActorSystem` that enables certain system specific serialization operations, such as
    /// looking up actors.
    open func setSerializationContext(_: Serialization.Context) {
        // nothing by default, implementations may choose to not care
    }

    open func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        // nothing by default, implementations may choose to not care
    }
}

extension Serializer: AnySerializer {
    public func _asSerializerOf<M>(_: M.Type) -> Serializer<M> {
        self as! Serializer<M>
    }

    public func trySerialize(_ message: Any) throws -> Serialization.Buffer {
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
    public func tryDeserialize(_ buffer: Serialization.Buffer) throws -> Any {
        try self.deserialize(from: buffer)
    }

    public var asAnySerializer: AnySerializer {
        BoxedAnySerializer(self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: NonTransportableSerializer

internal class NonTransportableSerializer<Message>: Serializer<Message> {
    override func serialize(_ message: Message) throws -> Serialization.Buffer {
        throw SerializationError.unableToSerialize(hint: "\(Self.self): \(Message.self)")
    }

    override func deserialize(from bytes: Serialization.Buffer) throws -> Message {
        throw SerializationError.unableToDeserialize(hint: "\(Self.self): \(Message.self)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializers: AnySerializer

/// Abstracts over different Encoder/Decoder and other serialization mechanisms.
///
/// Serializers may directly work on ``NIO.ByteBuffer`` or on ``Foundation.Data``.
///
/// - Warning: This type may be replaced if we managed to pull Combine's "TopLevelEncoder" types into stdlib.
public protocol AnySerializer {
    func trySerialize(_ message: Any) throws -> Serialization.Buffer

    func tryDeserialize(_ buffer: Serialization.Buffer) throws -> Any

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?)
    func setSerializationContext(_ context: Serialization.Context)
}

internal struct BoxedAnySerializer: AnySerializer, CustomStringConvertible {
    private let serializer: AnySerializer

    init<Serializer: AnySerializer>(_ serializer: Serializer) {
        self.serializer = serializer
    }

    func setSerializationContext(_ context: Serialization.Context) {
        self.serializer.setSerializationContext(context)
    }

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.serializer.setUserInfo(key: key, value: value)
    }

    func trySerialize(_ message: Any) throws -> Serialization.Buffer {
        try self.serializer.trySerialize(message)
    }

    func tryDeserialize(_ bytes: Serialization.Buffer) throws -> Any {
        try self.serializer.tryDeserialize(bytes)
    }

    public var description: String {
        "AnySerializer(\(self.serializer))"
    }
}
