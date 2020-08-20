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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ProtoActorAddress

extension ActorAddress: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoActorAddress

    public func toProto(context: Serialization.Context) throws -> ProtoActorAddress {
        var address = ProtoActorAddress()
        let node = self.node
        address.node = try node.toProto(context: context)

        address.path.segments = self.segments.map { $0.value }
        address.incarnation = self.incarnation.value

        return address
    }

    public init(fromProto proto: ProtoActorAddress, context: Serialization.Context) throws {
        let uniqueNode: UniqueNode = try .init(fromProto: proto.node, context: context)

        // TODO: make Error
        let path = try ActorPath(proto.path.segments.map { try ActorPathSegment($0) })

        self.init(remote: uniqueNode, path: path, incarnation: ActorIncarnation(proto.incarnation))
    }
}

extension UniqueNode: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoUniqueNode

    public func toProto(context: Serialization.Context) throws -> ProtoUniqueNode {
        var proto = ProtoUniqueNode()
        proto.nid = self.nid.value
        proto.node.protocol = self.node.protocol
        proto.node.system = self.node.systemName
        proto.node.hostname = self.node.host
        proto.node.port = UInt32(self.node.port)

        return proto
    }

    public init(fromProto proto: ProtoUniqueNode, context: Serialization.Context) throws {
        let node = Node(
            protocol: proto.node.protocol,
            systemName: proto.node.system,
            host: proto.node.hostname,
            port: Int(proto.node.port)
        )

        self = .init(node: node, nid: UniqueNodeID(proto.nid))
    }
}

extension ActorRef: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoActorAddress

    public func toProto(context: Serialization.Context) throws -> ProtoActorAddress {
        try self.address.toProto(context: context)
    }

    public init(fromProto proto: ProtoActorAddress, context: Serialization.Context) throws {
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
// MARK: ProtoUniqueNode

extension UniqueNode {
    init(_ proto: ProtoUniqueNode) throws {
        guard proto.hasNode else {
            throw SerializationError.missingField("address", type: String(describing: UniqueNode.self))
        }
        guard proto.nid != 0 else {
            throw SerializationError.missingField("uid", type: String(describing: UniqueNode.self))
        }
        let node = Node(proto.node)
        let nid = UniqueNodeID(proto.nid)
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
// MARK: ProtoNode

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
