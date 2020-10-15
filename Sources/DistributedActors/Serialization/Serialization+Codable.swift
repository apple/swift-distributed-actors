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

import Foundation // JSON and PList coders
import struct Foundation.Data

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Decodable + _decode(bytes:using:SomeDecoder) extensions

// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)
extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: JSONDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer.readData())
    }

    static func _decode<C>(from container: inout C, forKey key: C.Key, using decoder: Decoder) throws -> Self
        where C: KeyedDecodingContainerProtocol {
        try container.decode(Self.self, forKey: key)
    }
}

extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: PropertyListDecoder, format _format: PropertyListSerialization.PropertyListFormat) throws -> Self {
        var format = _format
        return try decoder.decode(Self.self, from: buffer.readData(), format: &format)
    }
}

extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: TopLevelBytesBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

extension Decodable {
    static func _decode(from buffer: Serialization.Buffer, using decoder: TopLevelProtobufBlobDecoder) throws -> Self {
        try decoder.decode(Self.self, from: buffer)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Encodable + _encode(bytes:using:SomeDecoder) extensions

// TODO: once we can abstract over Coders all these could go away most likely (and accept a generic TopLevelCoder)

extension Encodable {
    func _encode(using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(self)
    }
}

extension Encodable {
    func _encode(using encoder: PropertyListEncoder) throws -> Data {
        try encoder.encode(self)
    }
}

extension Encodable {
    func _encode(using encoder: TopLevelBytesBlobEncoder) throws -> Serialization.Buffer {
        try encoder.encode(self)
    }
}

extension Encodable {
    func _encode(using encoder: TopLevelProtobufBlobEncoder) throws -> Serialization.Buffer {
        try encoder.encode(self)
    }
}
