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
// MARK: CRDT.VersionedContainer

extension CRDT.VersionedContainer: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTVersionedContainer

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTVersionedContainer {
        var proto = ProtoCRDTVersionedContainer()
        proto.replicaID = self.replicaId.toProto(context: context)

        proto.versionContext = try self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTVersionedContainer, context: ActorSerializationContext) throws {
        switch proto.replicaID.value {
        case .some(.actorAddress(let protoAddress)):
            self.replicaId = try .actorAddress(ActorAddress(protoAddress))
        case .none:
            throw SerializationError.missingField("replicaID", type: String(reflecting: ProtoCRDTVersionedContainer.self))
        }

        guard proto.hasVersionContext else {
            throw SerializationError.missingField("versionContext", type: String(describing: ReplicaId.self))
        }
        self.versionContext = try .init(fromProto: proto.versionContext, context: context)
        self.elementByBirthDot = try .init(fromProto: proto.elementByBirthDot, context: context)
        if proto.hasDelta {
            self.delta = try .init(fromProto: proto.delta, context: context)
        } else {
            self.delta = nil
        }
    }
}

extension CRDT.VersionedContainerDelta: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTVersionedContainerDelta

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTVersionedContainerDelta {
        var proto = ProtoCRDTVersionedContainerDelta()
        proto.versionContext = try self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        return proto
    }

    init(fromProto proto: ProtoCRDTVersionedContainerDelta, context: ActorSerializationContext) throws {
        guard proto.hasVersionContext else {
            throw SerializationError.missingField("versionContext", type: String(describing: ReplicaId.self))
        }
        self.versionContext = try .init(fromProto: proto.versionContext, context: context)
        self.elementByBirthDot = try .init(fromProto: proto.elementByBirthDot, context: context)
    }
}

private extension Dictionary where Key == VersionDot, Value: Hashable {
    func toProto(context: ActorSerializationContext) throws -> [ProtoVersionDottedElementEnvelope] {
        var envelopes: [ProtoVersionDottedElementEnvelope] = []
        envelopes.reserveCapacity(self.count)
        for (dot, element) in self {
            var envelope = ProtoVersionDottedElementEnvelope()
            envelope.dot = try dot.toProto(context: context)

            let serializerId = try context.system.serialization.serializerIdFor(message: element)
            guard let serializer = context.system.serialization.serializer(for: serializerId) else {
                throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: Key.self))
            }
            envelope.serializerID = serializerId
            var bytes = try serializer.trySerialize(element)
            envelope.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes

            envelopes.append(envelope)
        }
        return envelopes
    }

    init(fromProto proto: [ProtoVersionDottedElementEnvelope], context: ActorSerializationContext) throws {
        var dict: [VersionDot: Value] = [:]
        dict.reserveCapacity(proto.count)
        for envelope in proto {
            guard envelope.hasDot else {
                throw SerializationError.missingField("envelope.dot", type: "\(String(reflecting: [VersionDot: Value].self))")
            }

            // TODO: avoid having to alloc, but deser from Data directly
            var bytes = context.allocator.buffer(capacity: envelope.payload.count)
            bytes.writeBytes(envelope.payload)

            let payload = try context.system.serialization.deserialize(serializerId: envelope.serializerID, from: bytes)
            let key = try VersionDot(fromProto: envelope.dot, context: context)
            dict[key] = payload as? Value
        }

        self = dict
    }
}

extension CRDT.VersionContext: InternalProtobufRepresentable {
    typealias InternalProtobufRepresentation = ProtoCRDTVersionContext

    func toProto(context: ActorSerializationContext) throws -> ProtoCRDTVersionContext {
        var proto = ProtoCRDTVersionContext()
        proto.versionVector = try self.vv.toProto(context: context)
        proto.gaps = try self.gaps.map { gap in
            try gap.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTVersionContext, context: ActorSerializationContext) throws {
        self.vv = try .init(fromProto: proto.versionVector, context: context)
        self.gaps = []
        self.gaps.reserveCapacity(proto.gaps.count)
        for versionDot in proto.gaps {
            guard versionDot.hasReplicaID else {
                throw SerializationError.missingField("replicaID", type: String(describing: CRDT.VersionContext.self))
            }
            guard let replicaId = versionDot.replicaID.value else {
                throw SerializationError.missingField("replicaID.value", type: String(describing: ReplicaId.self))
            }
            switch replicaId {
            case .actorAddress(let address):
                try self.gaps.insert(VersionDot(.actorAddress(ActorAddress(address)), Int(versionDot.version)))
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.GCounter

extension CRDT.GCounter {
    fileprivate typealias State = [ReplicaId: Int]
    fileprivate typealias ProtoState = [ProtoCRDTGCounter.ReplicaState]
}

extension CRDT.GCounter.State {
    fileprivate init(fromProto proto: CRDT.GCounter.ProtoState, context: ActorSerializationContext) throws {
        self = try proto.reduce(into: [ReplicaId: Int]()) { result, replicaState in
            let replicaId = try ReplicaId(fromProto: replicaState.replicaID, context: context)
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
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    init(fromProto proto: ProtoCRDTGCounter, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.GCounter.self))
        }
        self.init(replicaId: try ReplicaId(fromProto: proto.replicaID, context: context))
        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)
        if proto.hasDelta {
            self.delta = try .init(fromProto: proto.delta, context: context)
        }
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ORSet

extension CRDT.ORSet: ProtobufRepresentable {
    public typealias InternalProtobufRepresentation = ProtoCRDTORSet

    public func toProto(context: ActorSerializationContext) throws -> ProtoCRDTORSet {
        var proto = ProtoCRDTORSet()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTORSet, context: ActorSerializationContext) throws {
        switch proto.replicaID.value {
        case .some(.actorAddress(let protoAddress)):
            self.replicaId = try .actorAddress(.init(protoAddress))
        case .none:
            throw SerializationError.missingField("replicaID", type: String(reflecting: CRDT.ORSet<Element>.self))
        }
        self.state = try .init(fromProto: proto.state, context: context)
    }
}
