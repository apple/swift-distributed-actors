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
import NIOFoundationCompat
import SwiftProtobuf

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Serializer

@usableFromInline
internal class StringSerializer: TypeSpecificSerializer<String> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(message: String) throws -> ByteBuffer {
        let len = message.lengthOfBytes(using: .utf8) // TODO: optimize for ascii?
        var buffer = self.allocate.buffer(capacity: len)
        buffer.writeString(message)
        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> String {
        guard let s = bytes.getString(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.notAbleToDeserialize(hint: String(reflecting: String.self))
        }
        return s
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Number Serializer

@usableFromInline
internal class NumberSerializer<Number: FixedWidthInteger>: TypeSpecificSerializer<Number> {
    private let allocate: ByteBufferAllocator

    init(_: Number.Type, _ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(message: Number) throws -> ByteBuffer {
        var buffer = self.allocate.buffer(capacity: MemoryLayout<Number>.size)
        buffer.writeInteger(message, as: Number.self)
        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> Number {
        if let i = bytes.getInteger(at: 0, endianness: .big, as: Number.self) {
            return i
        } else {
            throw SerializationError.notAbleToDeserialize(hint: "\(bytes) as \(Number.self)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: JSON Codable Serializer

internal final class JSONCodableSerializer: CodableManifestSerializer, CustomStringConvertible {
    private let allocate: ByteBufferAllocator
    internal var encoder: JSONEncoder = JSONEncoder()
    internal var decoder: JSONDecoder = JSONDecoder()

    init(allocator: ByteBufferAllocator) {
        self.allocate = allocator
        super.init()
    }

    override func serialize<T: Encodable>(_ message: T) throws -> ByteBuffer {
//        guard let context: ActorSerializationContext = self.encoder.actorSerializationContext else {
//            throw ActorCoding.CodingError.missingActorSerializationContext(Any.self, details: "While encoding [\(String(reflecting: T.self))], using [\(self.encoder)]")
//        }
//        guard let encodeable = message as? (T & Encodable) else {
//            throw ActorCoding.CodingError.unableToSerialize(hint: "Passed in \(String(reflecting: T.self)) is NOT Encodable")
//        }

//        let manifest: Serialization.Manifest = try context.outboundManifest(T.self)
//        let manifest = Serialization.Manifest(serializerID: .jsonCodable, hint: manifest)

        let data = try encoder.encode(message)
        var bytes = self.allocate.buffer(capacity: data.count)
        bytes.writeBytes(data)

        traceLog_Serialization("serialized to: \(data)")
        return bytes
    }

    override func deserialize(from bytes: ByteBuffer, using manifest: Serialization.Manifest) throws -> Any {
        guard let context: ActorSerializationContext = decoder.actorSerializationContext else {
            throw ActorCoding.CodingError.missingActorSerializationContext(Any.self, details: "While decoding [\(manifest)], using [\(self.decoder)]")
        }
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            fatalError("Could not read data! Was: \(bytes), trying to deserialize manifest: \(manifest)")
        }

        guard let type: Decodable = try context.summonType(from: manifest) as? Codable else {
            throw ActorCoding.CodingError.missingManifest(hint: "FAILED !!!!")
        }

        return try self.decoder.decode(type, from: data)
    }

    override func setSerializationContext(_ context: ActorSerializationContext) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }

    override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.encoder.userInfo[key] = value
        self.decoder.userInfo[key] = value
    }

    var description: String {
        "JSONCodableSerializer(allocate: \(self.allocate), encoder: \(self.encoder), decoder: \(self.decoder))"
    }
}
