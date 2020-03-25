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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Top-Level Bytes-Blob Encoder

// TODO: TopLevelDataEncoder

class TopLevelBytesBlobEncoder: _TopLevelBlobEncoder {
    let allocator: ByteBufferAllocator

    var result: ByteBuffer?

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    var codingPath: [CodingKey] {
        []
    }

    var userInfo: [CodingUserInfoKey: Any] = [:]

    func encode<T>(_ value: T) throws -> ByteBuffer where T : Encodable {
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

        var result = self.allocator.buffer(capacity: data.count)
        result.writeBytes(data)
        self.result = result
    }

    func store(buffer: ByteBuffer) throws {
        guard self.result == nil else {
            throw SerializationError.unableToSerialize(hint: "Already encoded a single value, yet attempted to store another in \(Self.self)")
        }

        self.result = buffer
    }

    func store(bytes: [UInt8]) throws {
        guard self.result == nil else {
            throw SerializationError.unableToSerialize(hint: "Already encoded a single value, yet attempted to store another in \(Self.self)")
        }

        var result = self.allocator.buffer(capacity: bytes.count)
        result.writeBytes(bytes)
        self.result = result
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        fatalError("Cannot use KeyedEncodingContainer with \(Self.self)")
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        fatalError()
        // TopLevelBytesBlobEncoderContainer(superEncoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        TopLevelBytesBlobSingleValueEncodingContainer(superEncoder: self)
    }
}

struct TopLevelBytesBlobSingleValueEncodingContainer: SingleValueEncodingContainer {
    private(set) var codingPath: [CodingKey] = []

    let superEncoder: TopLevelBytesBlobEncoder

    init(superEncoder: TopLevelBytesBlobEncoder) {
        self.superEncoder = superEncoder
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        switch value {
        case let data as Data:
            try self.superEncoder.store(data: data)
        case let buffer as ByteBuffer:
            try self.superEncoder.store(buffer: buffer)
        case let bytes as [UInt8]:
            try self.superEncoder.store(bytes: bytes)
        default:
            throw SerializationError.unableToSerialize(hint: "Attempted encode \(T.self) into a \(Self.self) which only suports raw bytes")
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

// struct TopLevelBytesBlobEncoderContainer: UnkeyedEncodingContainer {
//    private(set) var codingPath: [CodingKey] = []
//    private(set) var count: Int = 0
//
//    let superEncoder: TopLevelBytesBlobEncoder
//
//    init(superEncoder: TopLevelBytesBlobEncoder) {
//        self.superEncoder = superEncoder
//    }
//
//    // ==== ------------------------------------------------------------------------------------------------------------
//    // MARK: Not supported operations
//
//    func encode<T>(_ value: T) throws where T: Encodable {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encodeNil() throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Bool) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: String) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Double) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Float) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Int) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Int8) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Int16) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Int32) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: Int64) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: UInt) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: UInt8) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: UInt16) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: UInt32) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode(_ value: UInt64) throws {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func encode<T>(contentsOf sequence: T) throws where T: Sequence, T.Element: Encodable {
//        throw SerializationError.unableToSerialize(hint: "\(#function) for \(value) failed! Only a top-level blob of bytes can be serialized by \(Self.self)!")
//    }
//
//    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
//        fatalError("nestedContainer(keyedBy:) is not supported by \(Self.self)")
//    }
//
//    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
//        fatalError("nestedUnkeyedContainer() is not supported by \(Self.self)")
//    }
//
// }

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Top-Level Bytes-Blob Decoder

// TODO: TopLevelDataDecoder

class TopLevelBytesBlobDecoder: _TopLevelBlobDecoder {
    typealias Input = ByteBuffer
    private(set) var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        fatalError("container(keyedBy:) has not been implemented")
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        fatalError("unkeyedContainer() has not been implemented")
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        TopLevelBytesBlobSingleValueDecodingContainer(superEncoder: self)
    }

    func decode<T>(_ type: T.Type, from: Input) throws -> T where T: Decodable {
        var buf = from
        return try T._decode(from: &buf, using: TopLevelProtobufBlobDecoder()) // FIXME: should be the proto one
    }
}

struct TopLevelBytesBlobSingleValueDecodingContainer: SingleValueDecodingContainer {
    let superEncoder: TopLevelBytesBlobDecoder

    private(set) var codingPath: [CodingKey] = []

    init(superEncoder: TopLevelBytesBlobDecoder) {
        self.superEncoder = superEncoder
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        fatalError("attempted to decode \(T.self) from \(Self.self)")
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
