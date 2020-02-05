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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ReplicaId

extension ReplicaId: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoVersionReplicaId

    public func toProto(context: ActorSerializationContext) throws -> ProtoVersionReplicaId {
        var proto = ProtoVersionReplicaId()
        switch self {
        case .actorAddress(let actorAddress):
            proto.actorAddress = try actorAddress.toProto(context: context)
        case .uniqueNode(let node):
            proto.uniqueNode = try node.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoVersionReplicaId, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: ReplicaId.self))
        }

        switch value {
        case .actorAddress(let protoActorAddress):
            let actorAddress = try ActorAddress(fromProto: protoActorAddress, context: context)
            self = .actorAddress(actorAddress)
        case .uniqueNode(let protoNode):
            let node = try UniqueNode(fromProto: protoNode, context: context)
            self = .uniqueNode(node)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionVector

extension VersionVector: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoVersionVector

    public func toProto(context: ActorSerializationContext) throws -> ProtoVersionVector {
        var proto = ProtoVersionVector()

        let replicaVersions: [ProtoReplicaVersion] = try self.state.map { replicaId, version in
            var replicaVersion = ProtoReplicaVersion()
            replicaVersion.replicaID = try replicaId.toProto(context: context)
            replicaVersion.version = UInt64(version)
            return replicaVersion
        }
        proto.state = replicaVersions

        return proto
    }

    public init(fromProto proto: ProtoVersionVector, context: ActorSerializationContext) throws {
        // `state` defaults to [:]
        self.state.reserveCapacity(proto.state.count)

        for replicaVersion in proto.state {
            guard replicaVersion.hasReplicaID else {
                throw SerializationError.missingField("replicaID", type: String(describing: ReplicaVersion.self))
            }
            let replicaId = try ReplicaId(fromProto: replicaVersion.replicaID, context: context)
            state[replicaId] = replicaVersion.version
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionDot

extension VersionDot: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoVersionDot

    public func toProto(context: ActorSerializationContext) throws -> ProtoVersionDot {
        var proto = ProtoVersionDot()
        proto.replicaID = try self.replicaId.toProto(context: context)
        proto.version = UInt64(self.version)
        return proto
    }

    public init(fromProto proto: ProtoVersionDot, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: VersionDot.self))
        }
        self.replicaId = try ReplicaId(fromProto: proto.replicaID, context: context)
        self.version = proto.version
    }
}
