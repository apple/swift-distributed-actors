//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ActorID

extension ActorID: Codable {
    public func encode(to encoder: Encoder) throws {
        let metadataSettings = encoder.actorSerializationContext?.system.settings.actorMetadata
        let encodeCustomMetadata =
            metadataSettings?.encodeCustomMetadata ?? ({ _, _ in () })

        var container = encoder.container(keyedBy: ActorCoding.CodingKeys.self)
        try container.encode(self.node, forKey: ActorCoding.CodingKeys.node)
        try container.encode(self.path, forKey: ActorCoding.CodingKeys.path)  // TODO: remove as we remove the tree
        try container.encode(self.incarnation, forKey: ActorCoding.CodingKeys.incarnation)

        if !self.metadata.isEmpty {
            var metadataContainer = container.nestedContainer(keyedBy: ActorCoding.MetadataKeys.self, forKey: ActorCoding.CodingKeys.metadata)

            let keys = ActorMetadataKeys.__instance
            func shouldPropagate<V: Sendable & Codable>(_ key: ActorMetadataKey<V>, metadata: ActorMetadata) -> V? {
                if metadataSettings == nil || metadataSettings!.propagateMetadata.contains(key.id) {
                    if let value = metadata[key.id] {
                        let value = value as! V  // as!-safe, the keys guarantee we only store well typed values in metadata
                        return value
                    }
                }
                return nil
            }

            // Handle well known metadata types
            if let value = shouldPropagate(keys.path, metadata: self.metadata) {
                try metadataContainer.encode(value, forKey: ActorCoding.MetadataKeys.path)
            }
            if let value = shouldPropagate(keys.type, metadata: self.metadata) {
                try metadataContainer.encode(value.mangledName, forKey: ActorCoding.MetadataKeys.type)
            }
            if let value = shouldPropagate(keys.wellKnown, metadata: self.metadata) {
                try metadataContainer.encode(value, forKey: ActorCoding.MetadataKeys.wellKnown)
            }

            try encodeCustomMetadata(self.metadata, &metadataContainer)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActorCoding.CodingKeys.self)
        let node = try container.decode(Cluster.Node.self, forKey: ActorCoding.CodingKeys.node)
        let path = try container.decodeIfPresent(ActorPath.self, forKey: ActorCoding.CodingKeys.path)
        let incarnation = try container.decode(UInt32.self, forKey: ActorCoding.CodingKeys.incarnation)

        self.init(remote: node, path: path, incarnation: ActorIncarnation(incarnation))

        // Decode any tags:
        if let metadataContainer = try? container.nestedContainer(keyedBy: ActorCoding.MetadataKeys.self, forKey: ActorCoding.CodingKeys.metadata) {
            // tags container found, try to decode all known tags:

            let metadata = ActorMetadata()
            if let value = try? metadataContainer.decodeIfPresent(ActorPath.self, forKey: ActorCoding.MetadataKeys.path) {
                metadata.path = value
            }
            if let value = try? metadataContainer.decodeIfPresent(String.self, forKey: ActorCoding.MetadataKeys.type) {
                metadata.type = .init(mangledName: value)
            }
            if let value = try? metadataContainer.decodeIfPresent(String.self, forKey: ActorCoding.MetadataKeys.wellKnown) {
                metadata.wellKnown = value
            }

            if let context = decoder.actorSerializationContext {
                let decodeCustomMetadata = context.system.settings.actorMetadata.decodeCustomMetadata
                try decodeCustomMetadata(metadataContainer, self.metadata)

                //                for (key, value) in try decodeCustomMetadata(metadataContainer) {
                //                    func store(_: K.Type) {
                //                        if let value = tag.value as? K.Value {
                //                            self.metadata[K.self] = value
                //                        }
                //                    }v
                //                    _openExistential(key, do: store) // the `as` here is required, because: inferred result type 'any ActorTagKey.Type' requires explicit coercion due to loss of generic requirements
                //                }
            }

            self.context = .init(lifecycle: nil, remoteCallInterceptor: nil, metadata: metadata)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ProtoActorID

extension ActorID: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoActorID

    public func toProto(context: Serialization.Context) throws -> _ProtoActorID {
        let metadataSettings = context.system.settings.actorMetadata

        var proto = _ProtoActorID()
        let node = self.node
        proto.node = try node.toProto(context: context)

        proto.path.segments = self.segments.map(\.value)
        proto.incarnation = self.incarnation.value

        if !self.metadata.isEmpty {
            let keys = ActorMetadataKeys.__instance
            func shouldPropagate<V: Sendable & Codable>(_ key: ActorMetadataKey<V>, metadata: ActorMetadata) -> V? {
                if metadataSettings.propagateMetadata.contains(key.id) {
                    if let value = metadata[key.id] {
                        let value = value as! V  // as!-safe, the keys guarantee we only store well typed values in metadata
                        return value
                    }
                }
                return nil
            }

            // Handle well known metadata types
            if let value = shouldPropagate(keys.path, metadata: self.metadata) {
                let serialized = try context.serialization.serialize(value)
                proto.metadata[keys.path.id] = serialized.buffer.readData()
            }
            if let value = shouldPropagate(keys.type, metadata: self.metadata) {
                let serialized = try context.serialization.serialize(value.mangledName)
                proto.metadata[keys.type.id] = serialized.buffer.readData()
            }
            if let value = shouldPropagate(keys.wellKnown, metadata: self.metadata) {
                let serialized = try context.serialization.serialize(value)
                proto.metadata[keys.wellKnown.id] = serialized.buffer.readData()
            }

            // FIXME: implement custom metadata transporting https://github.com/apple/swift-distributed-actors/issues/987
        }

        return proto
    }

    public init(fromProto proto: _ProtoActorID, context: Serialization.Context) throws {
        let node: Cluster.Node = try .init(fromProto: proto.node, context: context)

        let path = try ActorPath(proto.path.segments.map { try ActorPathSegment($0) })

        self.init(remote: node, path: path, incarnation: ActorIncarnation(proto.incarnation))

        // Handle well known metadata
        if !proto.metadata.isEmpty {
            let keys = ActorMetadataKeys.__instance

            // Path is handled already explicitly in the above ActorID initializer
            // TODO: Uncomment impl when we move to entirely not using paths at all:
            //            if let data = proto.metadata[keys.type.id] {
            //                let manifest = Serialization.Manifest.stringSerializerManifest
            //                let serialized = Serialization.Serialized(manifest: manifest, buffer: .data(data))
            //                if let value = try? context.serialization.deserialize(as: String.self, from: serialized) {
            //                    self.metadata.type = .init(mangledName: value)
            //                }
            //            }
            if let data = proto.metadata[keys.type.id] {
                let manifest = try context.serialization.outboundManifest(String.self)
                let serialized = Serialization.Serialized(manifest: manifest, buffer: .data(data))
                if let value = try? context.serialization.deserialize(as: String.self, from: serialized) {
                    self.metadata.type = .init(mangledName: value)
                }
            }

            if let data = proto.metadata[keys.wellKnown.id] {
                let manifest = try context.serialization.outboundManifest(String.self)
                let serialized = Serialization.Serialized(manifest: manifest, buffer: .data(data))
                if let value = try? context.serialization.deserialize(as: String.self, from: serialized) {
                    self.metadata.wellKnown = value
                }
            }
        }
    }
}

extension Cluster.Node: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoClusterNode

    public func toProto(context: Serialization.Context) throws -> _ProtoClusterNode {
        var proto = _ProtoClusterNode()
        proto.nid = self.nid.value
        proto.endpoint.protocol = self.endpoint.protocol
        proto.endpoint.system = self.endpoint.systemName
        proto.endpoint.hostname = self.endpoint.host
        proto.endpoint.port = UInt32(self.endpoint.port)

        return proto
    }

    public init(fromProto proto: _ProtoClusterNode, context: Serialization.Context) throws {
        let endpoint = Cluster.Endpoint(
            protocol: proto.endpoint.protocol,
            systemName: proto.endpoint.system,
            host: proto.endpoint.hostname,
            port: Int(proto.endpoint.port)
        )

        self = .init(endpoint: endpoint, nid: Cluster.Node.ID(proto.nid))
    }
}

extension _ActorRef: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoActorID

    public func toProto(context: Serialization.Context) throws -> _ProtoActorID {
        try self.id.toProto(context: context)
    }

    public init(fromProto proto: _ProtoActorID, context: Serialization.Context) throws {
        self = context._resolveActorRef(Message.self, identifiedBy: try ActorID(fromProto: proto, context: context))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ProtoActorPath

extension ActorPath {
    init(_ proto: _ProtoActorPath) throws {
        guard !proto.segments.isEmpty else {
            throw SerializationError(.emptyRepeatedField("path.segments"))
        }

        self.segments = try proto.segments.map { try ActorPathSegment($0) }
    }
}

extension _ProtoActorPath {
    init(_ value: ActorPath) {
        self.segments = value.segments.map(\.value)  // TODO: avoiding the mapping could be nice... store segments as strings?
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ProtoClusterNode

extension Cluster.Node {
    init(_ proto: _ProtoClusterNode) throws {
        guard proto.hasEndpoint else {
            throw SerializationError(.missingField("endpoint", type: String(describing: Cluster.Node.self)))
        }
        guard proto.nid != 0 else {
            throw SerializationError(.missingField("uid", type: String(describing: Cluster.Node.self)))
        }
        let endpoint = Cluster.Endpoint(proto.endpoint)
        let nid = Cluster.Node.ID(proto.nid)
        self.init(endpoint: endpoint, nid: nid)
    }
}

extension _ProtoClusterNode {
    init(_ node: Cluster.Node) {
        self.endpoint = _ProtoClusterEndpoint(node.endpoint)
        self.nid = node.nid.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ProtoClusterEndpoint

extension Cluster.Endpoint {
    init(_ proto: _ProtoClusterEndpoint) {
        self.protocol = proto.protocol
        self.systemName = proto.system
        self.host = proto.hostname
        self.port = Int(proto.port)
    }
}

extension _ProtoClusterEndpoint {
    init(_ endpoint: Cluster.Endpoint) {
        self.protocol = endpoint.protocol
        self.system = endpoint.systemName
        self.hostname = endpoint.host
        self.port = UInt32(endpoint.port)
    }
}
