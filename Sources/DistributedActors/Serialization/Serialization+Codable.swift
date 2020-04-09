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

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Decodable + _decode(bytes:using:SomeDecoder) extensions

// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)
extension Decodable {
    static func _decode(from buffer: inout NIO.ByteBuffer, using decoder: JSONDecoder) throws -> Self {
        let readableBytes = buffer.readableBytes

        return try buffer.withUnsafeMutableReadableBytes {
            // we are getting the pointer from a ByteBuffer, so it should be valid and force unwrap should be fine
            let data = Data(bytesNoCopy: $0.baseAddress!, count: readableBytes, deallocator: .none)
            return try decoder.decode(Self.self, from: data)
        }
    }
}

extension Decodable {
    static func _decode(from buffer: inout NIO.ByteBuffer, using decoder: TopLevelBytesBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

extension Decodable {
    static func _decode(from buffer: inout NIO.ByteBuffer, using decoder: TopLevelProtobufBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Encodable + _encode(bytes:using:SomeDecoder) extensions

// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)

extension Encodable {
    func _encode(using encoder: JSONEncoder, allocator: ByteBufferAllocator) throws -> NIO.ByteBuffer {
        try encoder.encodeAsByteBuffer(self, allocator: allocator)
    }
}

extension Encodable {
    func _encode(using encoder: TopLevelBytesBlobEncoder) throws -> NIO.ByteBuffer {
        try encoder.encode(self)
    }
}

extension Encodable {
    func _encode(using encoder: TopLevelProtobufBlobEncoder) throws -> NIO.ByteBuffer {
        try encoder.encode(self)
    }
}
