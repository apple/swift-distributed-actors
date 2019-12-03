//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XPC
import NIO

/// Serialization to and from `xpc_object_t`.
///
/// Encapsulates logic how actorables encode messages when putting them through the XPC transport.
// TODO: could also encode using the NS coding scheme, or "raw" if we want to support those.
public enum XPCSerialization {

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialize

    public static func serializeActorMessage<Message>(_ system: ActorSystem, message: Message) throws -> xpc_object_t {
        let serializerId = try system.serialization.serializerIdFor(message: message)

        guard let serializer = system.serialization.serializer(for: serializerId) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "\(Message.self))")
        }

        // TODO: mark that this invocation will be over XPC somehow; serializer.setSerializationContext(<#T##context: ActorSerializationContext##ActorSerializationContext#>)

        let buf = try serializer.trySerialize(message)

        // TODO serialize the Envelope
        let xdict: xpc_object_t = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue, UInt64(serializerId))

        buf.withUnsafeReadableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue, UInt64(buf.readableBytes))
                xpc_dictionary_set_data(xdict, ActorableXPCMessageField.message.rawValue, baseAddress, buf.readableBytes)
            }
        }

        return xdict
    }

    public static func serializeRecipient(_ system: ActorSystem, xdict: xpc_object_t, address: ActorAddress) throws {
        guard let addressSerializerId = try system.serialization.serializerIdFor(type: ActorAddress.self) else {
            fatalError("Can't serialize ActorAddress")
        }
        guard let serializer = try system.serialization.serializer(for: addressSerializerId) else {
            fatalError("Can't serialize ActorAddress")
        }

        let buf = try serializer.trySerialize(address)
        buf.withUnsafeReadableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                xpc_dictionary_set_data(xdict, ActorableXPCMessageField.recipientAddress.rawValue, baseAddress, buf.readableBytes)
            }
        }
    }

    // TODO: serializeRawDict - for C apis interop

    // TODO: serializeNSXPCStyle - for NSXPC services interop

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Deserialize

    public static func deserializeActorMessage(_ system: ActorSystem, peer: xpc_connection_t, xdict: xpc_object_t) throws -> Any {
        let serializerId = UInt32(xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue))

        guard let serializer = system.serialization.serializer(for: serializerId) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "SerializerId:\(serializerId))")
        }

        // FIXME This means we need to make those value types (!!!!!!!)
        // by storing the peer connection, we make the Codable infra deserialize a proxy that will reply to this peer
        serializer.setUserInfo(key: .xpcConnection, value: peer)

        let length64 = xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue)
        var length = Int(length64)

        let rawDataPointer: UnsafeRawPointer? = xpc_dictionary_get_data(xdict, ActorableXPCMessageField.message.rawValue, &length)
        let rawDataBufferPointer = UnsafeRawBufferPointer.init(start: rawDataPointer, count: length)

        var buf = system.serialization.allocator.buffer(capacity: 0)
        buf.writeBytes(rawDataBufferPointer)

        do {
            return try serializer.tryDeserialize(buf)
        } catch {
            // TODO only nowadays since we know its JSON
            throw XPCSerializationError.decodingError(payload: buf.getString(at: 0, length: buf.readableBytes) ?? "<no payload>", error: error)
        }
    }

    // TODO make as envelope
    public static func deserializeRecipient(_ system: ActorSystem, xdict: xpc_object_t) throws -> AddressableActorRef {
        let length64 = xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.recipientLength.rawValue)
        var length = Int(length64)

        let rawDataPointer: UnsafeRawPointer? = xpc_dictionary_get_data(xdict, ActorableXPCMessageField.recipientAddress.rawValue, &length)
        let rawDataBufferPointer = UnsafeRawBufferPointer.init(start: rawDataPointer, count: length)

        var buf = system.serialization.allocator.buffer(capacity: 0)
        buf.writeBytes(rawDataBufferPointer)

        do {
            guard let id = system.serialization.serializerIdFor(type: ActorAddress.self) else {
                return system.deadLetters.asAddressable()
            }
            guard let serializer = system.serialization.serializer(for: id) else {
                return system.deadLetters.asAddressable()
            }
            let address = try serializer.tryDeserialize(buf) as! ActorAddress
            return system._resolveUntyped(context: ResolveContext(address: address, system: system))
        } catch {
            // TODO only nowadays since we know its JSON
            throw XPCSerializationError.decodingError(payload: buf.getString(at: 0, length: buf.readableBytes) ?? "<no recipient>", error: error)
        }

    }
}

public enum XPCSerializationError: Error {
    case decodingError(payload: String, error: Error)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: User info

extension Decoder {
    public var xpcConnection: xpc_connection_t? {
        self.userInfo[.xpcConnection] as? xpc_connection_t
    }
}

extension Encoder {
    public var xpcConnection: xpc_connection_t? {
        self.userInfo[.xpcConnection] as? xpc_connection_t
    }
}

public extension CodingUserInfoKey {
    static let xpcConnection: CodingUserInfoKey = CodingUserInfoKey(rawValue: "XPCConnection")!
}
