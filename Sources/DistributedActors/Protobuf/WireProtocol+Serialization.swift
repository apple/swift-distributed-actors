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

import struct Foundation.Data // TODO: would refer to not go "through" Data as our target always is ByteBuffer
import NIO
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoEnvelope

enum WireEnvelopeError: Error {
    case missingManifest
    case emptyRecipient
}

// TODO: ProtobufRepresentable?

extension Wire.Envelope {
    init(_ proto: ProtoEnvelope, allocator: ByteBufferAllocator) throws {
        guard proto.hasRecipient else {
            throw WireEnvelopeError.emptyRecipient
        }
        guard proto.hasManifest else {
            throw WireEnvelopeError.missingManifest
        }

        self.recipient = try ActorAddress(fromProto: proto.recipient)

        var payloadBuffer = allocator.buffer(capacity: proto.payload.count)
        payloadBuffer.writeBytes(proto.payload)
        self.payload = payloadBuffer
        self.manifest = .init(fromProto: proto.manifest)
    }
}

extension ProtoEnvelope {
    init(_ envelope: Wire.Envelope) {
        self.recipient = ProtoActorAddress(envelope.recipient)

        self.manifest = .init()
        if let hint = envelope.manifest.hint {
            self.manifest.hint = hint
        }
        self.manifest.serializerID = envelope.manifest.serializerID.value

        var payloadBuffer = envelope.payload
        self.payload = payloadBuffer.readData(length: payloadBuffer.readableBytes)! // !-safe because we read exactly the number of readable bytes
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoProtocolVersion

// TODO: conversions are naive here, we'd want to express this more nicely...
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
            throw SerializationError.missingField("version", type: String(describing: Wire.HandshakeAccept.self))
        }
        guard proto.hasFrom else {
            throw SerializationError.missingField("from", type: String(describing: Wire.HandshakeAccept.self))
        }
        guard proto.hasOrigin else {
            throw SerializationError.missingField("hasOrigin", type: String(describing: Wire.HandshakeAccept.self))
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
            throw SerializationError.missingField("version", type: String(describing: Wire.HandshakeReject.self))
        }
        guard proto.hasFrom else {
            throw SerializationError.missingField("from", type: String(describing: Wire.HandshakeReject.self))
        }
        guard proto.hasOrigin else {
            throw SerializationError.missingField("origin", type: String(describing: Wire.HandshakeReject.self))
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
        self.reason = reject.reason
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: HandshakeOffer

extension Wire.HandshakeOffer {
    init(fromProto proto: ProtoHandshakeOffer) throws {
        guard proto.hasFrom else {
            throw SerializationError.missingField("from", type: String(reflecting: Wire.HandshakeOffer.self))
        }
        guard proto.hasTo else {
            throw SerializationError.missingField("to", type: String(reflecting: Wire.HandshakeOffer.self))
        }
        guard proto.hasVersion else {
            throw SerializationError.missingField("version", type: String(reflecting: Wire.HandshakeOffer.self))
        }

        self.from = try UniqueNode(proto.from)
        self.to = Node(proto.to)
        self.version = Wire.Version(reserved: UInt8(proto.version.reserved), major: UInt8(proto.version.major), minor: UInt8(proto.version.minor), patch: UInt8(proto.version.patch))
    }
}

extension ProtoHandshakeOffer {
    init(_ offer: Wire.HandshakeOffer) {
        self.version = ProtoProtocolVersion(offer.version)
        self.from = ProtoUniqueNode(offer.from)
        self.to = ProtoNode(offer.to)
    }

    init(serializedData data: Data) throws {
        var proto = ProtoHandshakeOffer()
        try proto.merge(serializedData: data)

        guard proto.hasVersion else {
            throw SerializationError.missingField("version", type: String(reflecting: Wire.HandshakeOffer.self))
        }
        guard proto.hasFrom else {
            throw SerializationError.missingField("from", type: String(reflecting: Wire.HandshakeOffer.self))
        }
        guard proto.hasTo else {
            throw SerializationError.missingField("to", type: String(reflecting: Wire.HandshakeOffer.self))
        }

        self = proto
    }
}
