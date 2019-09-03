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
internal class NumberSerializer<Number: FixedWidthInteger>: Serializer<Number> {
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
