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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: // MARK: Serialization with ByteBuf

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
        buffer.writeBytes(data)

        return buffer
    }

    /// Initializes the message from a `ByteBuffer` while trying to avoid copying its contents
    init(bytes: inout ByteBuffer) throws {
        self.init()
        let bytesCount = bytes.readableBytes
        try bytes.withUnsafeMutableReadableBytes {
            // we are getting the pointer from a ByteBuffer, so it should be valid and force unwrap should be fine
            try self.merge(serializedData: Data(bytesNoCopy: $0.baseAddress!, count: bytesCount, deallocator: .none))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoEnvelope

enum WireEnvelopeError: Error {
    case unsetSerializerId(UInt32)
    case emptyRecipient
}

extension Wire.Envelope {
    init(_ proto: ProtoEnvelope, allocator: ByteBufferAllocator) throws {
        guard proto.serializerID != 0 else {
            throw WireEnvelopeError.unsetSerializerId(proto.serializerID)
        }

        guard proto.hasRecipient else {
            throw WireEnvelopeError.emptyRecipient
        }

        self.recipient = try ActorAddress(proto.recipient)

        self.serializerId = proto.serializerID
        var payloadBuffer = allocator.buffer(capacity: proto.payload.count)
        payloadBuffer.writeBytes(proto.payload)
        self.payload = payloadBuffer
    }
}

extension ProtoEnvelope {
    init(_ envelope: Wire.Envelope) {
        self.recipient = ProtoActorAddress(envelope.recipient)

        self.serializerID = envelope.serializerId
        var payloadBuffer = envelope.payload
        self.payload = payloadBuffer.readData(length: payloadBuffer.readableBytes)! // !-safe because we read exactly the number of readable bytes
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoActorAddress

extension ActorAddress {
    init (_ proto: ProtoActorAddress) throws {
        let path = try ActorPath(proto.path.segments.map { try ActorPathSegment($0) })
        let incarnation = ActorIncarnation(Int(proto.incarnation))

        // TODO switch over senderNode | recipientNode | address
        if proto.hasNode {
            self = try ActorAddress(node: UniqueNodeAddress(proto.node), path: path, incarnation: incarnation)
        } else {
            self = ActorAddress(path: path, incarnation: incarnation)
        }
    }
}

extension ProtoActorAddress {
    init(_ value: ActorAddress) {
        if let node = value.node {
            self.node = .init(node)
        }
        self.path = .init(value.path)
        self.incarnation = value.incarnation.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoActorPath

extension ActorPath {
    init(_ proto: ProtoActorPath) throws {
        guard !proto.segments.isEmpty else {
            throw WireFormatError.emptyRepeatedField("path.segments")
        }

        self.segments = try proto.segments.map { try ActorPathSegment($0) }
    }
}

extension ProtoActorPath {
    init(_ value: ActorPath) {
        self.segments = value.segments.map { $0.value } // TODO avoiding the mapping could be nice... store segments as strings?
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoProtocolVersion

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
// MARK: ProtoHandshakeAccept

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


extension ProtoHandshakeAccept {
    init(_ accept: Wire.HandshakeAccept) {
        self.version = .init(accept.version)
        self.from = .init(accept.from)
        self.origin = .init(accept.origin)
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoHandshakeReject

extension Wire.HandshakeReject {
    init(_ proto: ProtoHandshakeReject) throws {
        guard proto.hasVersion else {
            throw WireFormatError.missingField("version")
        }
        guard proto.hasFrom else {
            throw WireFormatError.missingField("from")
        }
        guard proto.hasOrigin else {
            throw WireFormatError.missingField("origin")
        }

        self.version = .init(proto.version)
        self.from = .init(proto.from)
        self.origin = try .init(proto.origin)
        self.reason = proto.reason
    }
}


extension ProtoHandshakeReject {
    init(_ reject: Wire.HandshakeReject) {
        self.version = .init(reject.version)
        self.from = .init(reject.from)
        self.origin = .init(reject.origin)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UniqueNodeAddress

extension UniqueNodeAddress {
    init(_ proto: ProtoUniqueNodeAddress) throws {
        guard proto.hasAddress else {
            throw WireFormatError.missingField("address")
        }
        guard proto.nid != 0 else {
            throw WireFormatError.missingField("uid")
        }
        let address = NodeAddress(proto.address)
        let nid = NodeID(proto.nid)
        self.init(address: address, nid: nid)
    }
}

extension ProtoUniqueNodeAddress {
    init(_ address: UniqueNodeAddress) {
        self.address =  ProtoNodeAddress(address.address)
        self.nid = address.nid.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: NodeAddress

extension NodeAddress {
    init(_ proto: ProtoNodeAddress) {
        self.protocol = proto.protocol
        self.systemName = proto.system
        self.host = proto.hostname
        self.port = Int(proto.port)
    }
}

extension ProtoNodeAddress {
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
        self.version = ProtoProtocolVersion(offer.version)
        self.from = ProtoUniqueNodeAddress(offer.from)
        self.to = ProtoNodeAddress(offer.to)
    }

    init(serializedData data: Data) throws {
        var proto = ProtoHandshakeOffer()
        try proto.merge(serializedData: data)

        guard proto.hasVersion else {
            throw WireFormatError.missingField("version")
        }
        guard proto.hasFrom else {
            throw WireFormatError.missingField("from")
        }
        guard proto.hasTo else {
            throw WireFormatError.missingField("to")
        }

        self = proto
    }
}
