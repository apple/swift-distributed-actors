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

import NIO
import NIOFoundationCompat

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: JSON

/// Terrible workaround to automatically encode nils correctly on Swift 5.2, where Foundation encoders to not pass .allowFragments
internal protocol __OptionalProtocol {
    // Terrible workaround to survive `null` values on "top level" (as perceived by the Coders, since we may call them for values in our message)
    func __jsonEncode(using encoder: JSONEncoder) throws -> Data
    // Terrible workaround to survive `null` values on "top level" (as perceived by the Coders, since we may call them for values in our message)
    static func __jsonDecode(using decoder: JSONDecoder, from: Serialization.Buffer) throws -> Self
}

extension Optional: __OptionalProtocol where Wrapped: Codable {
    func __jsonEncode(using encoder: JSONEncoder) throws -> Data {
        switch self {
        case .some(let value):
            let data = try encoder.encode(value)
            return data
        case .none:
            return "null".data(using: .ascii)!
        }
    }

    static func __jsonDecode(using decoder: JSONDecoder, from bytes: Serialization.Buffer) throws -> Self {
        let data = bytes.readData()
        if String(data: data, encoding: .utf8) == "null" {
            return nil
        } else {
            return try decoder.decode(Self.self, from: data)
        }
    }
}

/// Allows for serialization of messages using the Foundation's `JSONEncoder` and `JSONDecoder`.
///
/// - Note: Take care to ensure that both "ends" (sending and receiving members of a cluster)
///   use the same encoding/decoding mechanism for a specific message.
// TODO: would be nice to be able to abstract over the coders (using TopLevelDecoder-like types) then rename this to `AnyCodableSerializer`
internal class JSONCodableSerializer<Message: Codable>: Serializer<Message> {
    internal var encoder: JSONEncoder
    internal var decoder: JSONDecoder

    public init(encoder: JSONEncoder = .init(), decoder: JSONDecoder = .init()) {
        self.encoder = encoder
        self.decoder = decoder
    }

    public override func serialize(_ message: Message) throws -> Serialization.Buffer {
        let data: Data
        #if swift(>=5.3)
        // It has .allowFragments set by default
        data = try encoder.encode(message)
        #else
        // terrible hack workaround, see __OptionalProtocol for details
        if let someOptional = message as? __OptionalProtocol {
            data = try someOptional.__jsonEncode(using: self.encoder)
        } else {
            data = try self.encoder.encode(message)
        }
        #endif
        traceLog_Serialization("serialized to: \(data)")
        return .data(data)
    }

    public override func deserialize(from buffer: Serialization.Buffer) throws -> Message {
        let data = buffer.readData()
        #if swift(>=5.3)
        // It has .allowFragments set by default
        return try self.decoder.decode(Message.self, from: data)
        #else
        // terrible hack workaround, see __OptionalProtocol for details
        if let OptionalMessageType = Message.self as? __OptionalProtocol.Type {
            return try OptionalMessageType.__jsonDecode(using: self.decoder, from: buffer) as! Message
        } else {
            return try self.decoder.decode(Message.self, from: data)
        }
        #endif
    }

    public override func setSerializationContext(_ context: Serialization.Context) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }

    public override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.encoder.userInfo[key] = value
        self.decoder.userInfo[key] = value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: PropertyList

/// Allows for serialization of messages using the Foundation's `PropertyListEncoder` and `PropertyListDecoder`, using the specified format.
///
/// - Note: Take care to ensure that both "ends" (sending and receiving members of a cluster)
///   use the same encoding/decoding mechanism for a specific message.
// TODO: would be nice to be able to abstract over the coders (using TopLevelDecoder-like types) then rename this to `AnyCodableSerializer`
internal class PropertyListCodableSerializer<Message: Codable>: Serializer<Message> {
    internal let encoder: PropertyListEncoder
    internal let decoder: PropertyListDecoder
    internal let format: PropertyListSerialization.PropertyListFormat

    public init(format: PropertyListSerialization.PropertyListFormat) {
        self.format = format
        self.encoder = PropertyListEncoder()
        self.encoder.outputFormat = format
        self.decoder = PropertyListDecoder()
    }

    public init(encoder: PropertyListEncoder = .init(), decoder: PropertyListDecoder = .init()) {
        self.encoder = encoder
        self.format = encoder.outputFormat
        self.decoder = decoder
    }

    public override func serialize(_ message: Message) throws -> Serialization.Buffer {
        let data = try encoder.encode(message)
        traceLog_Serialization("serialized to: \(data)")
        return .data(data)
    }

    public override func deserialize(from buffer: Serialization.Buffer) throws -> Message {
        var format = self.format
        // FIXME: validate format = self.format?
        return try self.decoder.decode(Message.self, from: buffer.readData(), format: &format)
    }

    public override func setSerializationContext(_ context: Serialization.Context) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }

    public override func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.encoder.userInfo[key] = value
        self.decoder.userInfo[key] = value
    }
}
