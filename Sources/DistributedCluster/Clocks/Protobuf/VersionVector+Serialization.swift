//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ReplicaID

extension ReplicaID: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoVersionReplicaID

    public func toProto(context: Serialization.Context) throws -> _ProtoVersionReplicaID {
        var proto = _ProtoVersionReplicaID()
        switch self.storage {
        case .actorID(let actorID):
            proto.actorID = try actorID.toProto(context: context)
//        case .actorIdentity(let actorIdentity):
//            proto.actorIdentity = try actorIdentity.toProto(context: context)
        case .node(let node):
            proto.node = try node.toProto(context: context)
        case .nodeID(let nid):
            proto.nodeID = nid.value
        }
        return proto
    }

    public init(fromProto proto: _ProtoVersionReplicaID, context: Serialization.Context) throws {
        guard let value = proto.value else {
            throw SerializationError(.missingField("value", type: String(describing: ReplicaID.self)))
        }

        switch value {
        case .actorID(let protoActorID):
            let actorID = try ActorID(fromProto: protoActorID, context: context)
            self = .actorID(actorID)
//        case .actorIdentity(let protoIdentity):
//            let id = try ClusterSystem.ActorID(fromProto: protoIdentity, context: context)
//            self = .actorIdentity(id)
        case .node(let protoNode):
            let node = try Cluster.Node(fromProto: protoNode, context: context)
            self = .node(node)
        case .nodeID(let nid):
            self = .nodeID(nid)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionVector

extension VersionVector: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoVersionVector

    public func toProto(context: Serialization.Context) throws -> _ProtoVersionVector {
        var proto = _ProtoVersionVector()

        let replicaVersions: [_ProtoReplicaVersion] = try self.state.map { replicaID, version in
            var replicaVersion = _ProtoReplicaVersion()
            replicaVersion.replicaID = try replicaID.toProto(context: context)
            replicaVersion.version = UInt64(version)
            return replicaVersion
        }
        proto.state = replicaVersions

        return proto
    }

    /// Serialize using nodeID specifically (or crash);
    /// Used in situations where an enclosing message already has the unique nodes serialized and we can save space by avoiding to serialize them again.
    public func toCompactReplicaNodeIDProto(context: Serialization.Context) throws -> _ProtoVersionVector {
        var proto = _ProtoVersionVector()

        let replicaVersions: [_ProtoReplicaVersion] = try self.state.map { replicaID, version in
            var replicaVersion = _ProtoReplicaVersion()
            switch replicaID.storage {
            case .node(let node):
                replicaVersion.replicaID.nodeID = node.nid.value
            case .nodeID(let nid):
                replicaVersion.replicaID.nodeID = nid.value
            case .actorID:
                throw SerializationError(.unableToSerialize(hint: "Can't serialize using actor address as replica id! Was: \(replicaID)"))
            }
            replicaVersion.version = UInt64(version)
            return replicaVersion
        }
        proto.state = replicaVersions

        return proto
    }

    public init(fromProto proto: _ProtoVersionVector, context: Serialization.Context) throws {
        // `state` defaults to [:]
        self.state.reserveCapacity(proto.state.count)

        for replicaVersion in proto.state {
            guard replicaVersion.hasReplicaID else {
                throw SerializationError(.missingField("replicaID", type: String(describing: ReplicaVersion.self)))
            }
            let replicaID = try ReplicaID(fromProto: replicaVersion.replicaID, context: context)
            state[replicaID] = replicaVersion.version
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionDot

extension VersionDot: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoVersionDot

    public func toProto(context: Serialization.Context) throws -> _ProtoVersionDot {
        var proto = _ProtoVersionDot()
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.version = UInt64(self.version)
        return proto
    }

    public init(fromProto proto: _ProtoVersionDot, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError(.missingField("replicaID", type: String(describing: VersionDot.self)))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)
        self.version = proto.version
    }
}
