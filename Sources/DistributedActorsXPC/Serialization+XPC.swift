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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

import DistributedActors
import Files
import NIO
import XPC

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt") // FIXME: remove hacky way to log

/// Serialization to and from `xpc_object_t`.
///
/// Encapsulates logic how actorables encode messages when putting them through the XPC transport.
// TODO: could also encode using the NS coding scheme, or "raw" if we want to support those.
public enum XPCSerialization {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialize

    public static func serializeActorMessage<Message>(_ system: ActorSystem, message: Message) throws -> xpc_object_t {
        let (manifest, buf) = try system.serialization.serialize(message)

        // TODO: mark that this invocation will be over XPC somehow; serializer.setSerializationContext(<#T##context: Serialization.Context##Serialization.Context#>)

        // TODO: serialize the Envelope
        let xdict: xpc_object_t = xpc_dictionary_create(nil, nil, 0)
        // xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.manifestHint.rawValue, manifest.hint ?? "") // FIXME: handle manifests
        xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue, UInt64(manifest.serializerID.value))

        buf.withUnsafeReadableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue, UInt64(buf.readableBytes))
                xpc_dictionary_set_data(xdict, ActorableXPCMessageField.message.rawValue, baseAddress, buf.readableBytes)
            }
        }

        return xdict
    }

    public static func serializeRecipient(_ system: ActorSystem, xdict: xpc_object_t, address: ActorAddress) throws {
        // we mutate the reference such that the recipient knows to reply back over the xpc connection
        var address = address
        address.node?.node.protocol = "xpc"
        try! _file.append("[sending] [TO: \(address)]\n")

        let (_, buf) = try system.serialization.serialize(address)
        buf.withUnsafeReadableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                // FIXME: what about manifest?
                xpc_dictionary_set_data(xdict, ActorableXPCMessageField.recipientAddress.rawValue, baseAddress, buf.readableBytes)
            }
        }
    }

    // TODO: serializeRawDict - for C apis interop

    // TODO: serializeNSXPCStyle - for NSXPC services interop

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Deserialize

    public static func deserializeActorMessage(_ system: ActorSystem, peer: xpc_connection_t, xdict: xpc_object_t) throws -> Any {
        // let manifestHint = Serialization.SerializerID(xpc_dictionary_get_string(xdict, ActorableXPCMessageField.manifestHint.rawValue)) // FIXME manifest?
        // let serializerID = Serialization.SerializerID(UInt32(xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue)))
        // let manifest = Serialization.Manifest(serializerID: serializerID, hint: manifestHint)

        fatalError("NOT IMPLEMENTED OVER MANIFESTS YET")

//        guard let serializer = system.serialization.serializer(for: serializerId) else {
//            throw SerializationError.noSerializerRegisteredFor(hint: "serializerID:\(serializerID))")
//        }
//
//        let length64 = xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue)
//        var length = Int(length64)
//
//        let rawDataPointer: UnsafeRawPointer? = xpc_dictionary_get_data(xdict, ActorableXPCMessageField.message.rawValue, &length)
//        let rawDataBufferPointer = UnsafeRawBufferPointer(start: rawDataPointer, count: length)
//
//        var buf = system.serialization.allocator.buffer(capacity: 0)
//        buf.writeBytes(rawDataBufferPointer)
//
//        do {
//            // FIXME: This means we need to make those value types (!!!!!!!)
//            // by storing the peer connection, we make the Codable infra deserialize a proxy that will reply to this peer
//            serializer.setUserInfo(key: .xpcConnection, value: peer) // FIXME: a `withUserInfo` would be a good way to solve it
//
//            return try serializer.tryDeserialize(buf)
//
//        } catch {
//            // TODO: only nowadays since we know its JSON
//            try! _file.append("FAILED: \(error)")
//            throw XPCSerializationError.decodingError(payload: buf.getString(at: 0, length: buf.readableBytes) ?? "<no payload>", error: error)
//        }
    }

    // TODO: make as envelope
    public static func deserializeRecipient(_ system: ActorSystem, xdict: xpc_object_t) throws -> AddressableActorRef {
        let length64 = xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.recipientLength.rawValue)
        var length = Int(length64)

        let rawDataPointer: UnsafeRawPointer? = xpc_dictionary_get_data(xdict, ActorableXPCMessageField.recipientAddress.rawValue, &length)
        let rawDataBufferPointer = UnsafeRawBufferPointer(start: rawDataPointer, count: length)

        let serialization: Serialization = system.serialization

        var buf = serialization.allocator.buffer(capacity: 0)
        buf.writeBytes(rawDataBufferPointer)

        do {
            let manifest: Serialization.Manifest = .init(serializerID: Serialization.SerializerID.foundationJSON, hint: "???")
            let address = try serialization.deserialize(as: ActorAddress.self, from: &buf, using: manifest)
            try! _file.append("\(#function) trying to resolve: \(address)")
            return system._resolveUntyped(context: ResolveContext(address: address, system: system))
        } catch {
            // TODO: only nowadays since we know its JSON
            try! _file.append("error: \(error)")
            throw XPCSerializationError.decodingError(payload: buf.getString(at: 0, length: buf.readableBytes) ?? "<no recipient>", error: error)
        }
    }
}

public enum XPCSerializationError: Error {
    case decodingError(payload: String, error: Error)
}

extension ActorPath {
    public static let _xpc: ActorPath = try! ActorPath(root: "xpc") // also known as "/"
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: User info

extension Decoder {
    public var xpcConnection: xpc_connection_t? {
        self.userInfo.xpcConnection
    }
}

extension Encoder {
    public var xpcConnection: xpc_connection_t? {
        self.userInfo.xpcConnection
    }
}

extension Dictionary where Key == CodingUserInfoKey, Value == Any {
    public var xpcConnection: xpc_connection_t? {
        self[.xpcConnection] as? xpc_connection_t
    }
}

public extension CodingUserInfoKey {
    static let xpcConnection: CodingUserInfoKey = CodingUserInfoKey(rawValue: "XPCConnection")!
}

#else
/// XPC is only available on Apple platforms
#endif
