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

// FIXME: remove?
// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)
extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: JSONDecoder) throws -> Self {
        let data: Data
        switch buffer {
        case .data(let d):
            data = d
        case .nioByteBuffer(var buffer):
            data = buffer.readData(length: buffer.readableBytes)! // safe since usign readableBytes
        }
        return try decoder.decode(Self.self, from: data)
    }
}

// FIXME: remove?
extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: PropertyListDecoder, format _format: PropertyListSerialization.PropertyListFormat) throws -> Self {
        let data: Data
        switch buffer {
        case .data(let d):
            data = d
        case .nioByteBuffer(var buffer):
            data = buffer.readData(length: buffer.readableBytes)! // safe since usign readableBytes
        }
        var format = _format
        return try decoder.decode(Self.self, from: data, format: &format)
    }
}

// FIXME: remove?
extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: TopLevelBytesBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

// FIXME: remove?
extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: TopLevelProtobufBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Encodable + _encode(bytes:using:SomeDecoder) extensions

// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)

// FIXME: remove
extension Encodable {
    func _encode(using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(self)
    }
}

// FIXME: remove?
extension Encodable {
    func _encode(using encoder: PropertyListEncoder) throws -> Data {
        try encoder.encode(self)
    }
}

// FIXME: remove?
extension Encodable {
    func _encode(using encoder: TopLevelBytesBlobEncoder) throws -> Serialization.Buffer {
        try encoder.encode(self)
    }
}

// FIXME: remove?
extension Encodable {
    func _encode(using encoder: TopLevelProtobufBlobEncoder) throws -> Serialization.Buffer {
        try encoder.encode(self)
    }
}
