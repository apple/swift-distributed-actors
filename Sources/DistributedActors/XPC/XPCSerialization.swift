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

        let buf = try serializer.trySerialize(message)

        let xdict: xpc_object_t = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue, UInt64(serializerId))

        pprint("xdict = \(xdict)")

        buf.withUnsafeReadableBytes { bytes in
            pprint("bytes = \(bytes)")
            if let baseAddress = bytes.baseAddress {
                xpc_dictionary_set_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue, UInt64(buf.readableBytes))
                xpc_dictionary_set_data(xdict, ActorableXPCMessageField.message.rawValue, baseAddress, buf.readableBytes)
                pprint("baseAddress = \(baseAddress)")
            }
        }

        return xdict
    }

    // TODO: serializeRawDict - for C apis interop

    // TODO: serializeNSXPCStyle - for NSXPC services interop

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Deserialize

    public static func deserializeActorMessage(_ system: ActorSystem, xdict: xpc_object_t) throws -> Any {
        let serializerId = UInt32(xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.serializerId.rawValue))
        pprint("serializerId = \(serializerId)")

        guard let serializer = system.serialization.serializer(for: serializerId) else {
            throw SerializationError.noSerializerRegisteredFor(hint: "SerializerId:\(serializerId))")
        }

        pprint("serializer = \(serializer)")

        let length64 = xpc_dictionary_get_uint64(xdict, ActorableXPCMessageField.messageLength.rawValue)
        pprint("length64 = \(length64)")
        var length = Int(length64)
        pprint("length = \(length)")

        let rawDataPointer: UnsafeRawPointer? = xpc_dictionary_get_data(xdict, ActorableXPCMessageField.message.rawValue, &length)
        pprint("rawDataPointer = \(rawDataPointer)")
        let rawDataBufferPointer = UnsafeRawBufferPointer.init(start: rawDataPointer, count: length)
        pprint("rawDataBufferPointer = \(rawDataBufferPointer)")

        var buf = system.serialization.allocator.buffer(capacity: 0)
        buf.writeBytes(rawDataBufferPointer)

        let anyMessage = try serializer.tryDeserialize(buf)
        pprint("anyMessage = \(anyMessage)")

        return anyMessage
    }

}
