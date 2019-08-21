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
    init(_ proto: ProtoActorAddress) throws {
        let path = try ActorPath(proto.path.segments.map { try ActorPathSegment($0) })
        let incarnation = ActorIncarnation(Int(proto.incarnation))

        // TODO: switch over senderNode | recipientNode | address
        if proto.hasNode {
            self = try ActorAddress(node: UniqueNode(proto.node), path: path, incarnation: incarnation)
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

extension ActorAddress: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoActorAddress

    func toProto(context: ActorSerializationContext) -> ProtoActorAddress {
        var address = ProtoActorAddress()
        let node = self.node ?? context.localNode
        address.node.nid = node.nid.value
        address.node.node.protocol = node.node.protocol
        address.node.node.system = node.node.systemName
        address.node.node.hostname = node.node.host
        address.node.node.port = UInt32(node.node.port)

        address.path.segments = self.segments.map { $0.value }
        address.incarnation = self.incarnation.value

        return address
    }

    init(fromProto proto: ProtoActorAddress, context: ActorSerializationContext) throws {
        let node = Node(
            protocol: proto.node.node.protocol,
            systemName: proto.node.node.system,
            host: proto.node.node.hostname,
            port: Int(proto.node.node.port)
        )

        let uniqueNode = UniqueNode(node: node, nid: NodeID(proto.node.nid))

        // TODO: make Error
        let path = try ActorPath(proto.path.segments.map { try ActorPathSegment($0) })

        self.init(node: uniqueNode, path: path, incarnation: ActorIncarnation(proto.incarnation))
    }
}

extension ActorRef: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoActorAddress

    func toProto(context: ActorSerializationContext) -> ProtoActorAddress {
        return self.address.toProto(context: context)
    }

    init(fromProto proto: ProtoActorAddress, context: ActorSerializationContext) throws {
        self = context.resolveActorRef(Message.self, identifiedBy: try ActorAddress(fromProto: proto, context: context))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoActorPath

extension ActorPath {
    init(_ proto: ProtoActorPath) throws {
        guard !proto.segments.isEmpty else {
            throw SerializationError.emptyRepeatedField("path.segments")
        }

        self.segments = try proto.segments.map { try ActorPathSegment($0) }
    }
}

extension ProtoActorPath {
    init(_ value: ActorPath) {
        self.segments = value.segments.map { $0.value } // TODO: avoiding the mapping could be nice... store segments as strings?
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
// MARK: UniqueNode

extension UniqueNode {
    init(_ proto: ProtoUniqueNode) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("address", type: String(describing: UniqueNode.self))
        }
        guard proto.nid != 0 else {
            throw SerializationError.missingField("uid", type: String(describing: UniqueNode.self))
        }
        let node = Node(proto.node)
        let nid = NodeID(proto.nid)
        self.init(node: node, nid: nid)
    }
}

extension ProtoUniqueNode {
    init(_ node: UniqueNode) {
        self.node = ProtoNode(node.node)
        self.nid = node.nid.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Node

extension Node {
    init(_ proto: ProtoNode) {
        self.protocol = proto.protocol
        self.systemName = proto.system
        self.host = proto.hostname
        self.port = Int(proto.port)
    }
}

extension ProtoNode {
    init(_ node: Node) {
        self.protocol = node.protocol
        self.system = node.systemName
        self.hostname = node.host
        self.port = UInt32(node.port)
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
