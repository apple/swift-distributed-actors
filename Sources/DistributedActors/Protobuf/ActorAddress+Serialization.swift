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
    public typealias ProtobufRepresentation = ProtoActorAddress

    public func toProto(context: ActorSerializationContext) -> ProtoActorAddress {
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

    public init(fromProto proto: ProtoActorAddress, context: ActorSerializationContext) throws {
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
    public typealias ProtobufRepresentation = ProtoActorAddress

    public func toProto(context: ActorSerializationContext) -> ProtoActorAddress {
        return self.address.toProto(context: context)
    }

    public init(fromProto proto: ProtoActorAddress, context: ActorSerializationContext) throws {
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
