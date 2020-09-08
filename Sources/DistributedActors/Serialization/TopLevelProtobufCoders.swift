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

import struct Foundation.Data
import struct NIO.ByteBuffer
import struct NIO.ByteBufferAllocator
import NIOFoundationCompat

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Top-Level Bytes-Blob Encoder

// TODO: TopLevelDataEncoder

final class TopLevelProtobufBlobEncoder: _TopLevelBlobEncoder {
    let allocator: ByteBufferAllocator

    var result: Serialization.Buffer?

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    var codingPath: [CodingKey] {
        []
    }

    var userInfo: [CodingUserInfoKey: Any] = [:]

    func encode<T>(_ value: T) throws -> Serialization.Buffer where T: Encodable {
        var container = self.singleValueContainer()
        try container.encode(value)
        guard let result = self.result else {
            throw SerializationError.unableToSerialize(hint: "No bytes were written while encoding \(value) using \(Self.self)!")
        }
        return result
    }

    func store(data: Data) throws {
        guard self.result == nil else {
            throw SerializationError.unableToSerialize(hint: "Already encoded a single value, yet attempted to store another in \(Self.self)")
        }

        self.result = .data(data)
    }

    func store(buffer: ByteBuffer) throws {
        guard self.result == nil else {
            throw SerializationError.unableToSerialize(hint: "Already encoded a single value, yet attempted to store another in \(Self.self)")
        }

        self.result = .nioByteBuffer(buffer)
    }

    func store(bytes: [UInt8]) throws {
        guard self.result == nil else {
            throw SerializationError.unableToSerialize(hint: "Already encoded a single value, yet attempted to store another in \(Self.self)")
        }

        var result = self.allocator.buffer(capacity: bytes.count)
        result.writeBytes(bytes)
        self.result = .nioByteBuffer(result)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        fatalError("Cannot use KeyedEncodingContainer with \(Self.self)")
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        fatalErrorBacktrace("Attempted \(#function) in \(self)")
        // TopLevelProtobufBlobEncoderContainer(superEncoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        TopLevelProtobufBlobSingleValueEncodingContainer(superEncoder: self)
    }
}

struct TopLevelProtobufBlobSingleValueEncodingContainer: SingleValueEncodingContainer {
    private(set) var codingPath: [CodingKey] = []

    let superEncoder: TopLevelProtobufBlobEncoder

    init(superEncoder: TopLevelProtobufBlobEncoder) {
        self.superEncoder = superEncoder
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        switch value {
        case let repr as AnyProtobufRepresentable:
            try repr.encode(to: self.superEncoder)
        case let data as Data:
            try data.encode(to: self.superEncoder)
        default:
            throw SerializationError.unableToSerialize(hint: "Attempted encode \(T.self) into a \(Self.self) which only supports ProtobufRepresentable")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Not supported operations

    func encodeNil() throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Bool) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: String) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Double) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Float) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Int) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Int8) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Int16) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Int32) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: Int64) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: UInt) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: UInt8) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: UInt16) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: UInt32) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }

    func encode(_ value: UInt64) throws {
        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Top-Level Bytes-Blob Decoder

class TopLevelProtobufBlobDecoder: _TopLevelBlobDecoder {
    typealias Input = ByteBuffer

    private(set) var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    var buffer: Serialization.Buffer?

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        fatalError("container(keyedBy:) has not been implemented")
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        fatalError("""
        \(#function)
         has not been implemented
        """)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        TopLevelProtobufBlobSingleValueDecodingContainer(superEncoder: self)
    }

    func decode<T>(_ type: T.Type, from buffer: Serialization.Buffer) throws -> T where T: Decodable {
        self.buffer = buffer

        if let P = type as? AnyProtobufRepresentable.Type {
            return try P.init(from: self) as! T // explicit .init() is required here (!)
        } else if let P = type as? AnyPublicProtobufRepresentable.Type {
            return try P.init(from: self) as! T // explicit .init() is required here (!)
        } else {
            return fatalErrorBacktrace("\(Self.self) is not able to decode \(T.self) as it isn't a ProtobufRepresentable type!")
        }
    }
}

struct TopLevelProtobufBlobSingleValueDecodingContainer: SingleValueDecodingContainer {
    let superEncoder: TopLevelProtobufBlobDecoder

    private(set) var codingPath: [CodingKey] = []

    init(superEncoder: TopLevelProtobufBlobDecoder) {
        self.superEncoder = superEncoder
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        guard let buffer = self.superEncoder.buffer else {
            fatalError("Super encoder has no bytes...!")
        }

        switch buffer {
        case .data(let data) where type is Foundation.Data.Type:
            return data as! T
        case .data where type is NIO.ByteBuffer.Type:
            return buffer.asByteBuffer(allocator: .init()) as! T

        case .nioByteBuffer(let buffer) where type is NIO.ByteBuffer.Type:
            return buffer as! T
        case .nioByteBuffer where type is Foundation.Data.Type:
            return buffer.readData() as! T

        default:
            throw SerializationError.unableToDeserialize(hint:
                "Attempted decode \(reflecting: type) from a \(Self.self) which only supports raw bytes (ByteBuffer or Data) \(type is Foundation.Data.Type)"
            )
        }
    }

    func decodeNil() -> Bool {
        false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: String.Type) throws -> String {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Double.Type) throws -> Double {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Float.Type) throws -> Float {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Int.Type) throws -> Int {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        throw SerializationError.unableToDeserialize(hint: "\(#function) failed! Only a top-level blob of bytes can be deserialized by \(Self.self)!")
    }
}
