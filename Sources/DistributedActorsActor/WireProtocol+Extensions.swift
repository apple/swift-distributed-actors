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

import SwiftProtobuf
import NIO
import struct Foundation.Data // TODO would refer to not go "through" Data as our target always is ByteBuffer

// MARK: Serialization with ByteBuf // TODO is forced to allocate more than it would have to normally (due to hop through Data)

extension SwiftProtobuf.Message {

    // FIXME: Avoid the copying, needs SwiftProtobuf changes
    /// Returns a `ByteBuffer` value containing the Protocol Buffer binary format serialization of the message.
    ///
    /// - Warning: Currently it is forced to perform an additional copy internally (so we double allocate the needed amount of space).
    ///
    /// - Parameters:
    ///   - partial: If `false` (the default), this method will check
    ///     `Message.isInitialized` before encoding to verify that all required
    ///     fields are present. If any are missing, this method throws
    ///     `BinaryEncodingError.missingRequiredFields`.
    /// - Returns: A `ByteBuffer` value containing the binary serialization of the message.
    /// - Throws: `BinaryEncodingError` if encoding fails.
    func serializedByteBuffer(allocator allocate: ByteBufferAllocator, partial: Bool = false) throws -> ByteBuffer {
         let data = try self.serializedData(partial: partial)
         // let data = try self.jsonString().data(using: .utf8)! // TODO allow a "debug mode with json payloads?"

        var buffer = allocate.buffer(capacity: data.count)
        buffer.write(bytes: data)

        return buffer
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Wire.Envelope

extension ProtoEnvelope {
    init(serializedData data: Data) throws {
        var proto = ProtoEnvelope()
        try proto.merge(serializedData: data)

        // guard proto.hasRecipient else { throw WireFormatError.missingField("recipient") }

        self = proto
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Wire.Version

// TODO conversions are naive here, we'd want to express this more nicely...
extension Wire.Version {
    init(_ proto: ProtoProtocolVersion) {
        self.reserved = UInt8(proto.reserved)
        self.major = UInt8(proto.major)
        self.minor = UInt8(proto.minor)
        self.patch = UInt8(proto.patch)
    }
}

extension ProtoProtocolVersion {
    init(_ value: Wire.Version) {
        var proto = ProtoProtocolVersion()
        proto.reserved = UInt32(value.reserved)
        proto.major = UInt32(value.major)
        proto.minor = UInt32(value.minor)
        proto.patch = UInt32(value.patch)
        self = proto
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Wire.HandshakeAccept from ProtoHandshakeAccept

extension Wire.HandshakeAccept {
    init(_ proto: ProtoHandshakeAccept) throws {
        guard proto.hasVersion else {
            throw WireFormatError.missingField("version")
        }
        guard proto.hasFrom else {
            throw WireFormatError.missingField("from")
        }
        guard proto.hasOrigin else {
            throw WireFormatError.missingField("hasOrigin")
        }
        self.version = .init(proto.version)
        self.from = try .init(proto.from)
        self.origin = try .init(proto.origin)

    }
}

// MARK: ProtoHandshakeAccept from Wire.HandshakeAccept
extension ProtoHandshakeAccept {
    init(_ accept: Wire.HandshakeAccept) {
        self.from = .init(accept.from)
        self.version = .init(accept.version)
        self.origin = .init(accept.origin)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UniqueNodeAddress

extension UniqueNodeAddress {
    init(_ proto: ProtoUniqueNodeAddress) throws {
        guard proto.hasAddress else {
            throw WireFormatError.missingField("address")
        }
        guard proto.uid != 0 else {
            throw WireFormatError.missingField("uid")
        }
        let address = NodeAddress(proto.address)
        let uid = NodeUID(proto.uid)
        self.init(address: address, uid: uid)
    }
}

extension ProtoUniqueNodeAddress {
    init(_ address: UniqueNodeAddress) {
        self.address = ProtoAddress(address.address)
        self.uid = address.uid.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: NodeAddress

extension NodeAddress {
    init(_ proto: ProtoAddress) {
        self.protocol = proto.protocol
        self.systemName = proto.system
        self.host = proto.hostname
        self.port = Int(proto.port)
    }
}

extension ProtoAddress {
    init(_ address: NodeAddress) {
        self.protocol = address.protocol
        self.system = address.systemName
        self.hostname = address.host
        self.port = UInt32(address.port)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: HandshakeOffer

extension Wire.HandshakeOffer {
    init(_ proto: ProtoHandshakeOffer) throws {
        guard proto.hasFrom else {
            throw WireFormatError.missingField("from")
        }
        guard proto.hasTo else {
            throw WireFormatError.missingField("to")
        }
        guard proto.hasVersion else {
            throw WireFormatError.missingField("version")
        }

        self.from = try UniqueNodeAddress(proto.from)
        self.to = NodeAddress(proto.to)
        self.version = Wire.Version(reserved: UInt8(proto.version.reserved), major: UInt8(proto.version.major), minor: UInt8(proto.version.minor), patch: UInt8(proto.version.patch))
    }
}

extension ProtoHandshakeOffer {
    init(_ offer: Wire.HandshakeOffer) {
        self.from = ProtoUniqueNodeAddress(offer.from)
        self.to = ProtoAddress(offer.to)
        self.version = ProtoProtocolVersion(offer.version)
    }

    init(serializedData data: Data) throws {
        var proto = ProtoHandshakeOffer()
        try proto.merge(serializedData: data)

        guard proto.hasFrom else {
            throw WireFormatError.missingField("from")
        }
        guard proto.hasTo else {
            throw WireFormatError.missingField("to")
        }
        guard proto.hasVersion else {
            throw WireFormatError.missingField("version")
        }

        self = proto
    }
}
