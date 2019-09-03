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
// MARK: VersionVector

extension VersionVector: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoVersionVector

    func toProto(context: ActorSerializationContext) throws -> ProtoVersionVector {
        var proto = ProtoVersionVector()

        var replicaVersions: [ProtoReplicaVersion] = []
        replicaVersions.reserveCapacity(self.state.count)
        for (replicaId, version) in self.state {
            var p = ProtoReplicaVersion()
            p.version = UInt32(version)

            var id = ProtoVersionReplicaId()
            switch replicaId {
            case .actorAddress(let address):
                id.actorAddress = address.toProto(context: context)
            }
            p.replicaID = id

            replicaVersions.append(p)
        }
        proto.state = replicaVersions
        return proto
    }

    init(fromProto proto: ProtoVersionVector, context: ActorSerializationContext) throws {
        self.state.reserveCapacity(proto.state.count)
        for pv in proto.state {
            let rid = try ReplicaId(fromProto: pv.replicaID, context: context)
            state[rid] = Int(pv.version)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ReplicaId

extension ReplicaId: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoVersionReplicaId

    func toProto(context: ActorSerializationContext) -> ProtoVersionReplicaId {
        var proto = ProtoVersionReplicaId()
        switch self {
        case .actorAddress(let actorAddress):
            proto.actorAddress = actorAddress.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoVersionReplicaId, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("value", type: String(describing: ReplicaId.self))
        }

        switch value {
        case .actorAddress(let address):
            let actorAddress = try ActorAddress(fromProto: address, context: context)
            self = .actorAddress(actorAddress)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionDot

extension VersionDot: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoVersionDot

    func toProto(context: ActorSerializationContext) throws -> ProtoVersionDot {
        var proto = ProtoVersionDot()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.version = UInt64(self.version)
        return proto
    }

    init(fromProto proto: ProtoVersionDot, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: VersionDot.self))
        }
        guard let replicaId = proto.replicaID.value else {
            throw SerializationError.missingField("replicaID.value", type: String(describing: VersionDot.self))
        }

        switch replicaId {
        case .actorAddress(let protoAddress):
            self.replicaId = try .actorAddress(.init(protoAddress))
        }
        self.version = Int(proto.version) // TODO: safety?
    }
}
