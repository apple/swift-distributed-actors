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
    static func _decode(from buffer: inout NIO.ByteBuffer, using decoder: PropertyListDecoder, format _format: PropertyListSerialization.PropertyListFormat) throws -> Self {
        let readableBytes = buffer.readableBytes

        return try buffer.withUnsafeMutableReadableBytes {
            // we are getting the pointer from a ByteBuffer, so it should be valid and force unwrap should be fine
            let data = Data(bytesNoCopy: $0.baseAddress!, count: readableBytes, deallocator: .none)
            var format = _format
            return try decoder.decode(Self.self, from: data, format: &format)
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
    func _encode(using encoder: PropertyListEncoder, allocator: ByteBufferAllocator) throws -> NIO.ByteBuffer {
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: PropertyListEncoder + encode(value:into:) extensions

// TODO: consider moving to NIOFoundationCompat where the JSONEncoder version exists

extension PropertyListEncoder {
    /// Writes a PropertyList-encoded representation of the value you supply into the supplied `ByteBuffer`.
    ///
    /// - parameters:
    ///     - value: The value to encode as PropertyList.
    ///     - buffer: The `ByteBuffer` to encode into.
    public func encode<T: Encodable>(_ value: T,
                                     into buffer: inout ByteBuffer) throws {
        try buffer.writePropertListEncodable(value, encoder: self)
    }

    /// Writes a PropertyList-encoded representation of the value you supply into a `ByteBuffer` that is freshly allocated.
    ///
    /// - parameters:
    ///     - value: The value to encode as PropertyList.
    ///     - allocator: The `ByteBufferAllocator` which is used to allocate the `ByteBuffer` to be returned.
    /// - returns: The `ByteBuffer` containing the encoded PropertyList.
    public func encodeAsByteBuffer<T: Encodable>(_ value: T, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let data = try self.encode(value)
        var buffer = allocator.buffer(capacity: data.count)
        try buffer.writePropertListEncodable(value, encoder: self)
        return buffer
    }
}

extension ByteBuffer {
    /// Encodes `value` using the `PropertListEncoder` `encoder` and writes the resulting bytes into this `ByteBuffer`.
    ///
    /// If successful, this will move the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - value: An `Encodable` value to encode.
    ///     - encoder: The `PropertListEncoder` to encode `value` with.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func writePropertListEncodable<T: Encodable>(_ value: T,
                                                                 encoder: PropertyListEncoder = PropertyListEncoder()) throws -> Int {
        let result = try self.setPropertListEncodable(value, encoder: encoder, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: result)
        return result
    }

    /// Encodes `value` using the `PropertListEncoder` `encoder` and set the resulting bytes into this `ByteBuffer` at the
    /// given `index`.
    ///
    /// - note: The `writerIndex` remains unchanged.
    ///
    /// - parameters:
    ///     - value: An `Encodable` value to encode.
    ///     - encoder: The `PropertListEncoder` to encode `value` with.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func setPropertListEncodable<T: Encodable>(_ value: T,
                                                               encoder: PropertyListEncoder = PropertyListEncoder(),
                                                               at index: Int) throws -> Int {
        let data = try encoder.encode(value)
        return self.setBytes(data, at: index)
    }
}
