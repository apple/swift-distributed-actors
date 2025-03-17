//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation  // for Codable
import NIO
import NIOFoundationCompat
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Serializer

@usableFromInline
internal class StringSerializer: Serializer<String> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(_ message: String) throws -> Serialization.Buffer {
        let len = message.lengthOfBytes(using: .utf8)
        var buffer = self.allocate.buffer(capacity: len)
        buffer.writeString(message)
        return .nioByteBuffer(buffer)
    }

    override func deserialize(from buffer: Serialization.Buffer) throws -> String {
        switch buffer {
        case .data(let data):
            guard let s = String(data: data, encoding: .utf8) else {
                throw SerializationError(.notAbleToDeserialize(hint: String(reflecting: String.self)))
            }
            return s
        case .nioByteBuffer(let buffer):
            guard let s = buffer.getString(at: 0, length: buffer.readableBytes) else {
                throw SerializationError(.notAbleToDeserialize(hint: String(reflecting: String.self)))
            }
            return s
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            throw SerializationError(.notAbleToDeserialize(hint: "\(Self.self) is [\(self)]. This should not happen, please file an issue."))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Number Serializer

@usableFromInline
internal class IntegerSerializer<Number: FixedWidthInteger>: Serializer<Number> {
    private let allocate: ByteBufferAllocator

    init(_: Number.Type, _ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(_ message: Number) throws -> Serialization.Buffer {
        var buffer = self.allocate.buffer(capacity: MemoryLayout<Number>.size)
        buffer.writeInteger(message, endianness: .big, as: Number.self)
        return .nioByteBuffer(buffer)
    }

    override func deserialize(from buffer: Serialization.Buffer) throws -> Number {
        switch buffer {
        case .data(let data):
            return Number(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Number.self) })
        case .nioByteBuffer(let buffer):
            guard let i = buffer.getInteger(at: 0, endianness: .big, as: Number.self) else {
                throw SerializationError(.notAbleToDeserialize(hint: "\(buffer) as \(Number.self)"))
            }
            return i
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            throw SerializationError(.notAbleToDeserialize(hint: "\(Self.self) is [\(self)]. This should not happen, please file an issue."))
        }
    }
}

@usableFromInline
internal class BoolSerializer: Serializer<Bool> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(_ message: Bool) throws -> Serialization.Buffer {
        var buffer = self.allocate.buffer(capacity: 1)
        let v: Int8 = message ? 1 : 0
        buffer.writeInteger(v)
        return .nioByteBuffer(buffer)
    }

    override func deserialize(from buffer: Serialization.Buffer) throws -> Bool {
        switch buffer {
        case .data(let data):
            let i = data.withUnsafeBytes { $0.load(as: Int8.self) }
            return i == 1
        case .nioByteBuffer(let buffer):
            guard let i = buffer.getInteger(at: 0, endianness: .big, as: Int8.self) else {
                throw SerializationError(.notAbleToDeserialize(hint: "\(buffer) as \(Bool.self) (1/0 Int8)"))
            }
            return i == 1
        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            throw SerializationError(.notAbleToDeserialize(hint: "\(Self.self) is [\(self)]. This should not happen, please file an issue."))
        }
    }
}
