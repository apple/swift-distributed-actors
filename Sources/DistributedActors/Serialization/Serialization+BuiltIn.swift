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
internal class StringSerializer: Serializer<String> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(_ message: String) throws -> ByteBuffer {
        let len = message.lengthOfBytes(using: .utf8) // TODO: optimize for ascii?
        var buffer = self.allocate.buffer(capacity: len)
        buffer.writeString(message)
        return buffer
    }

    override func deserialize(from bytes: ByteBuffer) throws -> String {
        guard let s = bytes.getString(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.notAbleToDeserialize(hint: String(reflecting: String.self))
        }
        return s
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

    override func serialize(_ message: Number) throws -> ByteBuffer {
        var buffer = self.allocate.buffer(capacity: MemoryLayout<Number>.size)
        buffer.writeInteger(message, endianness: .big, as: Number.self)
        return buffer
    }

    override func deserialize(from bytes: ByteBuffer) throws -> Number {
        if let i = bytes.getInteger(at: 0, endianness: .big, as: Number.self) {
            return i
        } else {
            throw SerializationError.notAbleToDeserialize(hint: "\(bytes) as \(Number.self)")
        }
    }
}

@usableFromInline
internal class BoolSerializer: Serializer<Bool> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(_ message: Bool) throws -> ByteBuffer {
        var buffer = self.allocate.buffer(capacity: 1)
        let v: Int8 = message ? 1 : 0
        buffer.writeInteger(v)
        return buffer
    }

    override func deserialize(from bytes: ByteBuffer) throws -> Bool {
        if let i = bytes.getInteger(at: 0, endianness: .big, as: Int8.self) {
            return i == 1
        } else {
            throw SerializationError.notAbleToDeserialize(hint: "\(bytes) as \(Bool.self) (1/0 Int8)")
        }
    }
}
