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

// TODO: could not get it to work
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: encode with manifest
//
// extension KeyedEncodingContainerProtocol {
//    mutating func encode<T>(_ value: T, forKey key: Self.Key, forManifestKey manifestKey: Self.Key) throws where T: Encodable {
//        let encoder = self.superEncoder()
//        guard let context: Serialization.Context = encoder.actorSerializationContext else {
//            throw SerializationError.missingSerializationContext(encoder, value)
//        }
//
//        let serialized = try context.serialization.serialize(value)
//
//        try self.encode(serialized.manifest, forKey: manifestKey)
//        try self.encode(serialized.buffer.readData(), forKey: key)
//    }
//
//
// }
//
// extension KeyedDecodingContainerProtocol {
//    func decode<T>(
//        _ type: T.Type, forKey key: Self.Key, forManifestKey manifestKey: Self.Key,
//        file: String = #file, line: UInt = #line
//    ) throws -> T where T: Decodable {
//        let decoder = self.superEncoder()
//
//        guard let context: Serialization.Context = decoder.actorSerializationContext else {
//            throw SerializationError.missingSerializationContext(T.self, details: "Missing context", file: file, line: line)
//        }
//
//        let manifest = try self.decode(Serialization.Manifest.self, forKey: manifestKey)
//        let data = try self.decode(Foundation.Data.self, forKey: manifestKey)
//
//        return try context.serialization.deserialize(as: T.self, from: .data(data), using: manifest)
//    }
//
// }
