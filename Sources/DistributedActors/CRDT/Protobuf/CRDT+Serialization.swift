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
// MARK: CRDT.Identity

extension CRDT.Identity: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTIdentity

    func toProto(context: ActorSerializationContext) -> ProtoCRDTIdentity {
        var proto = ProtoCRDTIdentity()
        proto.id = self.id
        return proto
    }

    init(fromProto proto: ProtoCRDTIdentity, context: ActorSerializationContext) {
        self.id = proto.id
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ReplicaId

extension CRDT.ReplicaId: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTReplicaId

    func toProto(context: ActorSerializationContext) -> ProtoCRDTReplicaId {
        var proto = ProtoCRDTReplicaId()
        switch self {
        case .actorAddress(let actorAddress):
            var aa = ProtoCRDTReplicaId_ActorAddress()
            aa.actorAddress = actorAddress.toProto(context: context)
            proto.actorAddress = aa
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTReplicaId, context: ActorSerializationContext) throws {
        guard let value = proto.value else {
            throw SerializationError.missingField("payload", type: String(describing: CRDT.ReplicaId.self))
        }

        switch value {
        case .actorAddress(let aa):
            guard aa.hasActorAddress else {
                throw SerializationError.missingField("actorAddress", type: "CRDT.ReplicaId.actorAddress")
            }
            let actorAddress = try ActorAddress(fromProto: aa.actorAddress, context: context)
            self = .actorAddress(actorAddress)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.GCounter

extension CRDT.GCounter {
    fileprivate typealias State = [CRDT.ReplicaId: Int]
    fileprivate typealias ProtoState = [ProtoCRDTGCounter.ReplicaState]
}

extension CRDT.GCounter.State {
    fileprivate init(fromProto proto: CRDT.GCounter.ProtoState, context: ActorSerializationContext) throws {
        self = try proto.reduce(into: [CRDT.ReplicaId: Int]()) { result, replicaState in
            let replicaId = try CRDT.ReplicaId(fromProto: replicaState.replicaID, context: context)
            result[replicaId] = Int(replicaState.count)
        }
    }
}

extension CRDT.GCounter.ProtoState {
    fileprivate init(fromValue value: CRDT.GCounter.State, context: ActorSerializationContext) {
        self = value.map { replicaId, count in
            var protoReplicaState = ProtoCRDTGCounter.ReplicaState()
            protoReplicaState.replicaID = replicaId.toProto(context: context)
            protoReplicaState.count = UInt64(count)
            return protoReplicaState
        }
    }
}

extension CRDT.GCounter: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTGCounter

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTGCounter {
        var proto = ProtoCRDTGCounter()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.state = CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        return proto
    }

    init(fromProto proto: ProtoCRDTGCounter, context: ActorSerializationContext) throws {
        self.init(replicaId: try CRDT.ReplicaId(fromProto: proto.replicaID, context: context))
        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)
    }
}

extension CRDT.GCounterDelta: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTGCounter.Delta

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTGCounter.Delta {
        var proto = ProtoCRDTGCounter.Delta()
        proto.state = CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        return proto
    }

    init(fromProto proto: ProtoCRDTGCounter.Delta, context: ActorSerializationContext) throws {
        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)
    }
}
